import Foundation

/// 本机命令行会话：接收终端的按键，做一行编辑，回车后交给 LocalShell 执行
@MainActor
final class LocalSession: TerminalSession {
    private let shell: LocalShell

    private var line: [Character] = []
    private var cursor = 0
    private var promptWidth = 0
    private var prompt = ""

    private var historyIndex: Int?
    private var draft = ""

    /// 正在运行的命令（ping、curl 这类要等一会儿的）；运行期间只响应 Ctrl+C
    private var running: Task<Void, Never>?

    /// 正在拼的转义序列（方向键等）和多字节字符
    private var escape: [UInt8] = []
    private var utf8: [UInt8] = []
    private var utf8Needed = 0

    override var title: String { tr("本机终端") }
    override var isLocal: Bool { true }
    override var limitedCommands: Bool { true }

    /// notice：为什么没能用上真 shell（有的话会显示在开场白里）
    init(shell: LocalShell, notice: String? = nil) {
        self.shell = shell
        super.init()
        state = .connected
        write(tr("\u{1B}[1m本机终端\u{1B}[0m  App 沙盒里的小命令行，输入 help 查看命令\n"))
        write(tr("ssh [用户@]主机 可以连接远程设备\n"))
        if let notice { write(tr("\u{1B}[90m真 shell 不可用：{0}\u{1B}[0m\n", notice)) }
        write("\n")
        showPrompt()
    }

    // MARK: - 输出

    /// 终端需要 \r\n 才会回到行首，这里统一把 \n 换掉
    private func write(_ text: String) {
        let converted = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        receive(Array(converted.utf8)[...])
    }

    private func showPrompt() {
        let (text, width) = shell.prompt()
        prompt = text
        promptWidth = width
        write(text)
    }

    /// 整行重画：用于历史、补全、清行等整行改变的情况
    private func redrawLine() {
        write("\r\u{1B}[2K" + prompt + String(line) + "\u{1B}[K")
        let tail = width(of: line[cursor...])
        if tail > 0 { write("\u{1B}[\(tail)D") }
    }

    private func width(of characters: ArraySlice<Character>) -> Int {
        characters.reduce(0) { $0 + LocalShell.displayWidth($1) }
    }

    // MARK: - 键盘输入

    override func send(_ bytes: ArraySlice<UInt8>) {
        bytes.forEach(handle)
    }

    override func resize(cols: Int, rows: Int) {
        shell.cols = cols
    }

    override func close() {
        running?.cancel()
        state = .closed
    }

    private func handle(_ byte: UInt8) {
        // 命令运行中：只认 Ctrl+C，其他按键先忽略
        if running != nil {
            if byte == 0x03 {
                write("^C\n")
                running?.cancel()
            }
            return
        }
        // 转义序列（方向键等）
        if !escape.isEmpty {
            escape.append(byte)
            if finishEscape() { escape = [] }
            return
        }
        if byte == 0x1B {
            escape = [byte]
            return
        }

        // 多字节字符
        if byte >= 0xC0 {
            utf8 = [byte]
            utf8Needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : 2
            return
        }
        if byte >= 0x80 {
            guard !utf8.isEmpty else { return }
            utf8.append(byte)
            if utf8.count == utf8Needed {
                String(decoding: utf8, as: UTF8.self).forEach(insert)
                utf8 = []
            }
            return
        }

        switch byte {
        case 0x0D, 0x0A: enter()
        case 0x7F, 0x08: backspace()
        case 0x09: tab()
        case 0x03: interrupt()
        case 0x04: endOfFile()
        case 0x0C: clearScreen()
        case 0x01: moveHome()
        case 0x05: moveEnd()
        case 0x15: killToStart()
        case 0x0B: killToEnd()
        case 0x17: killWord()
        case 0x20...0x7E: insert(Character(UnicodeScalar(byte)))
        default: break
        }
    }

    /// 返回 true 表示这个序列已经完整（或可以丢弃）
    private func finishEscape() -> Bool {
        guard escape.count >= 2 else { return false }
        let kind = escape[1]
        if kind == UInt8(ascii: "[") {
            guard let final = escape.last, escape.count >= 3, (0x40...0x7E).contains(final) else { return false }
            let params = String(decoding: escape[2..<escape.count - 1], as: UTF8.self)
            switch final {
            case UInt8(ascii: "A"): historyUp()
            case UInt8(ascii: "B"): historyDown()
            case UInt8(ascii: "C"): moveRight()
            case UInt8(ascii: "D"): moveLeft()
            case UInt8(ascii: "H"): moveHome()
            case UInt8(ascii: "F"): moveEnd()
            case UInt8(ascii: "~"):
                switch params {
                case "1", "7": moveHome()
                case "4", "8": moveEnd()
                case "3": deleteForward()
                default: break
                }
            default: break
            }
            return true
        }
        if kind == UInt8(ascii: "O") {
            guard escape.count >= 3 else { return false }
            switch escape[2] {
            case UInt8(ascii: "A"): historyUp()
            case UInt8(ascii: "B"): historyDown()
            case UInt8(ascii: "C"): moveRight()
            case UInt8(ascii: "D"): moveLeft()
            case UInt8(ascii: "H"): moveHome()
            case UInt8(ascii: "F"): moveEnd()
            default: break
            }
            return true
        }
        return true   // Alt+字符等，忽略
    }

    // MARK: - 行编辑

    private func insert(_ character: Character) {
        line.insert(character, at: cursor)
        cursor += 1
        let tail = line[cursor...]
        write(String(character) + String(tail))
        let back = width(of: tail)
        if back > 0 { write("\u{1B}[\(back)D") }
    }

    private func backspace() {
        guard cursor > 0 else { return }
        let removed = LocalShell.displayWidth(line[cursor - 1])
        cursor -= 1
        line.remove(at: cursor)
        let tail = line[cursor...]
        write("\u{1B}[\(removed)D" + String(tail) + String(repeating: " ", count: removed)
              + "\u{1B}[\(width(of: tail) + removed)D")
    }

    private func deleteForward() {
        guard cursor < line.count else { return }
        let removed = LocalShell.displayWidth(line[cursor])
        line.remove(at: cursor)
        let tail = line[cursor...]
        write(String(tail) + String(repeating: " ", count: removed) + "\u{1B}[\(width(of: tail) + removed)D")
    }

    private func moveLeft() {
        guard cursor > 0 else { return }
        cursor -= 1
        write("\u{1B}[\(LocalShell.displayWidth(line[cursor]))D")
    }

    private func moveRight() {
        guard cursor < line.count else { return }
        write("\u{1B}[\(LocalShell.displayWidth(line[cursor]))C")
        cursor += 1
    }

    private func moveHome() {
        let back = width(of: line[..<cursor])
        cursor = 0
        if back > 0 { write("\u{1B}[\(back)D") }
    }

    private func moveEnd() {
        let forward = width(of: line[cursor...])
        cursor = line.count
        if forward > 0 { write("\u{1B}[\(forward)C") }
    }

    private func killToStart() {
        line.removeSubrange(..<cursor)
        cursor = 0
        redrawLine()
    }

    private func killToEnd() {
        line.removeSubrange(cursor...)
        redrawLine()
    }

    private func killWord() {
        var start = cursor
        while start > 0, line[start - 1] == " " { start -= 1 }
        while start > 0, line[start - 1] != " " { start -= 1 }
        line.removeSubrange(start..<cursor)
        cursor = start
        redrawLine()
    }

    // MARK: - 历史

    private func historyUp() {
        let history = shell.history
        guard !history.isEmpty else { return }
        if let index = historyIndex {
            guard index > 0 else { return }
            historyIndex = index - 1
        } else {
            draft = String(line)
            historyIndex = history.count - 1
        }
        setLine(history[historyIndex!])
    }

    private func historyDown() {
        guard let index = historyIndex else { return }
        let history = shell.history
        if index < history.count - 1 {
            historyIndex = index + 1
            setLine(history[index + 1])
        } else {
            historyIndex = nil
            setLine(draft)
        }
    }

    private func setLine(_ text: String) {
        line = Array(text)
        cursor = line.count
        redrawLine()
    }

    // MARK: - 回车、中断、补全

    private func enter() {
        write("\n")
        let text = String(line)
        line = []
        cursor = 0
        historyIndex = nil

        running = Task { [weak self] in
            guard let self else { return }
            let result = await shell.execute(text) { [weak self] in self?.write($0) }
            running = nil
            if result.clear { write("\u{1B}[2J\u{1B}[H") }
            write(result.output)
            if result.exit {
                write("logout\n")
                state = .closed
                return
            }
            showPrompt()
        }
    }

    private func interrupt() {
        write("^C\n")
        line = []
        cursor = 0
        historyIndex = nil
        showPrompt()
    }

    private func endOfFile() {
        guard line.isEmpty else { return }
        write("logout\n")
        state = .closed
    }

    private func clearScreen() {
        write("\u{1B}[2J\u{1B}[H")
        write(prompt)
        redrawLine()
    }

    private func tab() {
        let (word, candidates) = shell.complete(String(line[..<cursor]))
        guard !candidates.isEmpty else { return }

        let common = candidates.dropFirst().reduce(candidates[0]) { prefix, next in
            String(zip(prefix, next).prefix { $0 == $1 }.map(\.0))
        }
        if common.count > word.count {
            common.dropFirst(word.count).forEach(insert)
            if candidates.count == 1, !common.hasSuffix("/") { insert(" ") }
            return
        }
        guard candidates.count > 1 else { return }

        // 没法再补全了，把候选列出来，再重画当前行
        write("\n" + candidates.joined(separator: "  ") + "\n")
        write(prompt)
        redrawLine()
    }
}
