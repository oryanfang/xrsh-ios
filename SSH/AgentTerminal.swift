import Foundation

/// 在终端里和 AI 对话：接管键盘，一行编辑；把 AgentSession 发生的事直接显示在终端上。
/// 期间设备的输出由 TerminalSession 存着，退出时再显示。
@MainActor
final class AgentTerminal {
    private enum Color {
        static let reset = "\u{1B}[0m"
        static let green = "\u{1B}[32m"
        static let cyan = "\u{1B}[36m"
        static let yellow = "\u{1B}[33m"
        static let red = "\u{1B}[31m"
        static let gray = "\u{1B}[90m"
    }

    private let agent: AgentSession
    private var session: TerminalSession
    private let onEnd: () -> Void
    private var ended = false

    private var line: [Character] = []
    /// 输入行的光标比第一行低几行（长句子会折行）
    private var cursorRow = 0
    private var inEscape = false
    private var escapeBytes = 0
    private var utf8: [UInt8] = []

    /// 在 tmux 的全屏画面里开始的：对话时切到普通屏幕，退出时切回去，tmux 的画面不会被弄乱
    private var fromAlternateScreen = false
    private var busy = false
    private var streaming = false
    /// AI 的话末尾的换行先不显示，这样说完时不会多出空行
    private var heldNewlines = 0

    init(agent: AgentSession, session: TerminalSession, prompt: String, onEnd: @escaping () -> Void) {
        self.agent = agent
        self.session = session
        self.onEnd = onEnd
        agent.onEvent = { [weak self] in self?.handle($0) }
        session.beginAgentMode { [weak self] in self?.input($0) }

        if session.isAlternateScreen() {
            fromAlternateScreen = true
            session.display("\u{1B}7\u{1B}[?47l\u{1B}[2J\u{1B}[H")
        } else {
            session.display("\r\n")
        }
        if prompt.isEmpty {
            show(tr("说一句你想做的事，比如：看看磁盘还剩多少。输入 /exit 回到终端。"), Color.gray)
            drawLine()
        } else {
            show(tr("输入 /exit 回到终端，Ctrl-C 停止。"), Color.gray)
            submit(prompt)
        }
    }

    /// AI 切换了设备：对话接到新的终端上
    func move(to newSession: TerminalSession) {
        session = newSession
        fromAlternateScreen = false
        newSession.beginAgentMode { [weak self] in self?.input($0) }
    }

    /// 结束对话，回到设备的终端
    func end() {
        guard !ended else { return }
        ended = true
        agent.onEvent = { _ in }
        agent.stop()
        clearBusy()
        session.display(Color.reset)
        if fromAlternateScreen { session.display("\u{1B}[?47h\u{1B}8") }
        session.endAgentMode(redrawPrompt: !fromAlternateScreen)
        onEnd()
    }

    // MARK: - 显示

    /// 设备输出和 AI 的话都不可信：去掉控制字符，防止它们控制终端（改写屏幕、伪造确认提示、写剪贴板）
    private func clean(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                result.append("\r")
                result.append(scalar)
            case 0x09:
                result.append(scalar)
            case 0x00..<0x20, 0x7F...0x9F:
                continue
            default:
                result.append(scalar)
            }
        }
        return String(result)
    }

    /// 显示完整的一段，并换行
    private func show(_ text: String, _ color: String = "") {
        clearBusy()
        session.display(color + clean(text) + Color.reset + "\r\n")
    }

    private func showBusy(_ text: String) {
        clearBusy()
        session.display(Color.gray + text + Color.reset)
        busy = true
    }

    private func clearBusy() {
        guard busy else { return }
        busy = false
        session.display("\r\u{1B}[K")
    }

    private func handle(_ event: AgentSession.Event) {
        switch event {
        case .text(let piece):
            streamText(piece)
            return
        case .textEnd:
            if streaming { session.display(Color.reset + "\r\n") }
            streaming = false
            heldNewlines = 0
        case .attached(let lines, let hidden):
            let title = tr("已带上最近 {0} 行终端输出", lines)
            show(hidden > 0 ? title + " · " + tr("{0} 处敏感信息已隐藏", hidden) : title, Color.gray)
        case .running(let command):
            show("$ " + command, Color.green)
            showBusy(tr("运行中…"))
            return
        case .ran(let result, let automatic, let hidden, let answeredPrompts):
            clearBusy()
            showOutput(result.output)
            let note = summary(result, automatic: automatic, hidden: hidden, answeredPrompts: answeredPrompts)
            if !note.isEmpty { show(note, Color.gray) }
        case .declined(let command):
            show(tr("已拒绝：{0}", command), Color.yellow)
        case .blocked(let command):
            show(tr("已禁止，没有运行：{0}", command), Color.red)
        case .switched(let title):
            show(tr("已切换到 {0}", title), Color.green)
        case .failed(let text):
            show(text, Color.yellow)
        case .confirm(let pending):
            showConfirm(pending)
            return
        case .finished:
            clearBusy()
            drawLine()
            return
        }
        if agent.isRunning, !streaming { showBusy(tr("思考中…")) }
    }

    private func streamText(_ piece: String) {
        var text = ""
        for scalar in clean(piece).unicodeScalars where scalar != "\r" {
            if scalar == "\n" {
                // 开头的换行不要
                if streaming || !text.isEmpty { heldNewlines += 1 }
                continue
            }
            if heldNewlines > 0 {
                text += String(repeating: "\r\n", count: heldNewlines)
                heldNewlines = 0
            }
            text.unicodeScalars.append(scalar)
        }
        guard !text.isEmpty else { return }
        clearBusy()
        session.display((streaming ? "" : Color.cyan) + text)
        streaming = true
    }

    /// 长输出只显示头尾；AI 拿到的是完整的
    private func showOutput(_ output: String) {
        let trimmed = output.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else {
            show(tr("（没有输出）"), Color.gray)
            return
        }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= 20 {
            show(trimmed)
        } else {
            show(lines.prefix(10).joined(separator: "\n"))
            show(tr("… 省略 {0} 行 …", lines.count - 20), Color.gray)
            show(lines.suffix(10).joined(separator: "\n"))
        }
    }

    private func summary(_ result: RemoteCommandResult, automatic: Bool, hidden: Int, answeredPrompts: Bool) -> String {
        var parts: [String] = []
        if automatic { parts.append(tr("只读，自动运行")) }
        if answeredPrompts { parts.append(tr("提示已自动回答 y")) }
        if result.timedOut {
            parts.append(tr("超时，已不再等待"))
        } else if let code = result.exitCode {
            parts.append(tr("退出码 {0}", code))
        }
        if result.truncated { parts.append(tr("输出太长，中间省略了一部分")) }
        if hidden > 0 { parts.append(tr("{0} 处敏感信息没有发给 AI", hidden)) }
        return parts.joined(separator: " · ")
    }

    private func showConfirm(_ pending: AgentSession.Pending) {
        switch pending {
        case .command(let command):
            show(tr("AI 想在设备上跑（可能会改动设备）："), Color.yellow)
            show(command, Color.green)
            if CommandSafety.answersPrompts(command), !session.limitedCommands {
                show(tr("允许后，安装过程中的提示会自动回答 y，也包括未签名软件源的确认。"), Color.yellow)
            }
        case .connect(let target):
            show(tr("AI 想切换到这台设备（会断开现在的连接）："), Color.yellow)
            show(target, Color.green)
        }
        session.display(tr("允许吗？(y/n) "))
    }

    // MARK: - 输入行

    private func width(_ text: [Character]) -> (row: Int, column: Int) {
        let columns = max(session.terminalColumns(), 8)
        var row = 0
        var column = 4   // "xr> "
        for character in text {
            let next = LocalShell.displayWidth(character)
            if column + next > columns {
                row += 1
                column = 0
            }
            column += next
        }
        return (row, column)
    }

    private func drawLine() {
        var text = "\r"
        if cursorRow > 0 { text += "\u{1B}[\(cursorRow)A" }
        text += "\u{1B}[J" + Color.green + "xr> " + Color.reset + clean(String(line))
        session.display(text)
        cursorRow = width(line).row
    }

    private func input(_ bytes: ArraySlice<UInt8>) {
        if agent.pending != nil {
            answer(bytes)
            return
        }
        if agent.isRunning {
            if bytes.contains(0x03) {
                clearBusy()
                if streaming { session.display(Color.reset + "\r\n") }
                streaming = false
                agent.stop()
            }
            return
        }
        for byte in bytes { edit(byte) }
    }

    /// 确认只认单独按下的一个键，粘贴进来的一段文字不算
    private func answer(_ bytes: ArraySlice<UInt8>) {
        if bytes.contains(0x03) {
            session.display("^C\r\n")
            agent.stop()
            return
        }
        // 中文键盘打出来的也认
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if ["y", "Y", "是", "好", "允许"].contains(text) {
            session.display("y\r\n")
            agent.answerConfirmation(true)
        } else if ["n", "N", "否", "不", "拒绝"].contains(text) {
            session.display("n\r\n")
            agent.answerConfirmation(false)
        }
    }

    private func edit(_ byte: UInt8) {
        // 方向键等转义序列都忽略；粘贴时的标记也是这种
        if inEscape {
            escapeBytes += 1
            if escapeBytes == 1 {
                if byte != UInt8(ascii: "["), byte != UInt8(ascii: "O") { inEscape = false }
            } else if (0x40...0x7E).contains(byte) {
                inEscape = false
            }
            return
        }
        if byte >= 0x80 {
            utf8.append(byte)
            let first = utf8[0]
            let needed = first >= 0xF0 ? 4 : first >= 0xE0 ? 3 : 2
            if utf8.count >= needed {
                line.append(contentsOf: String(decoding: utf8, as: UTF8.self))
                utf8 = []
                drawLine()
            }
            return
        }
        switch byte {
        case 0x1B:
            inEscape = true
            escapeBytes = 0
        case 0x0D, 0x0A:
            enter()
        case 0x7F, 0x08:
            if !line.isEmpty {
                line.removeLast()
                drawLine()
            }
        case 0x03:
            session.display("^C\r\n")
            cursorRow = 0
            line = []
            drawLine()
        case 0x04:
            if line.isEmpty {
                session.display("\r\n")
                end()
            }
        case 0x15:
            line = []
            drawLine()
        case 0x20...0x7E:
            line.append(Character(UnicodeScalar(byte)))
            drawLine()
        default:
            break
        }
    }

    private func enter() {
        session.display("\r\n")
        cursorRow = 0
        let text = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
        line = []
        switch text {
        case "":
            drawLine()
        case "/exit":
            end()
        case "/clear":
            agent.reset()
            show(tr("对话已清空。"), Color.gray)
            drawLine()
        default:
            submit(text)
        }
    }

    private func submit(_ text: String) {
        let output = AgentSettings.includeOutput ? session.recentOutput() : ""
        showBusy(tr("思考中…"))
        // 终端没有新内容就不用再带一遍
        if output.isEmpty || output == agent.lastOutput {
            agent.ask(text, attachment: nil)
        } else {
            agent.lastOutput = output
            agent.ask(text, attachment: output)
        }
    }
}
