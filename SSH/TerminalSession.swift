import Combine
import Foundation

/// 终端页里的一次会话。SSH 连接和本机命令行都继承它，共用同一套终端界面
@MainActor
class TerminalSession: ObservableObject {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
        case closed
    }

    @Published var state = State.connecting

    /// 导航栏标题
    var title: String { tr("终端") }
    /// 本机命令行（没有"重新连接"，只有"重新进入"）
    var isLocal: Bool { false }
    /// 越狱手机上的真 shell（命令按 iOS 越狱环境来，不是 Linux）
    var isDeviceShell: Bool { false }
    /// 只支持 App 自带小命令行里的那部分命令（面板里只显示它能跑的）
    var limitedCommands: Bool { false }
    /// 重新连接时要预填的主机；本机会话为 nil
    var reconnectHost: String? { nil }

    /// 终端视图设置后，输出会交给它；设置之前产生的输出先缓存
    var onOutput: ((ArraySlice<UInt8>) -> Void)? {
        didSet {
            guard let onOutput else { return }
            pending.forEach(onOutput)
            pending = []
        }
    }

    /// 终端视图设置：让它重新拿到键盘焦点
    var onFocusRequest: (() -> Void)?

    private var pending: [ArraySlice<UInt8>] = []

    /// 把要显示的字节交给终端视图
    func receive(_ bytes: ArraySlice<UInt8>) {
        recentBytes.append(contentsOf: bytes)
        if recentBytes.count > 32_000 { recentBytes.removeFirst(recentBytes.count - 16_000) }
        if agentInput != nil {
            // 和 AI 对话时设备的输出先存着，退出时再显示，不和对话混在一起
            held.append(bytes)
            heldCount += bytes.count
            if heldCount > 1_000_000 { flushHeld() }
        } else {
            deliver(bytes)
        }
    }

    private func deliver(_ bytes: ArraySlice<UInt8>) {
        if let onOutput {
            onOutput(bytes)
        } else {
            pending.append(bytes)
        }
    }

    private func flushHeld() {
        held.forEach(deliver)
        held = []
        heldCount = 0
    }

    func requestFocus() { onFocusRequest?() }

    /// 键盘输入
    func send(_ bytes: ArraySlice<UInt8>) {}
    func resize(cols: Int, rows: Int) {}
    func close() {}

    /// 能不能不经过终端、单独在设备上跑命令并拿回结果（agent 用）
    var canRunCommands: Bool { false }
    func runCommand(_ command: String, timeout: TimeInterval = 30) async throws -> RemoteCommandResult {
        throw NSError(domain: "SSH", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("现在只能在 SSH 连接上跑命令")])
    }

    // MARK: - agent

    /// 用户敲了 /xr，参数是后面带的那句话
    var onAgentRequest: ((String) -> Void)?

    /// 不为 nil 时正在和 AI 对话：键盘输入都交给它，不发给设备
    private(set) var agentInput: ((ArraySlice<UInt8>) -> Void)?
    private var held: [ArraySlice<UInt8>] = []
    private var heldCount = 0
    /// 终端视图设置：现在每行多少列
    var terminalColumns: () -> Int = { 80 }
    /// 退出对话时发给设备的按键：清掉这一行再回车，让 shell 重新显示提示符，不会执行任何东西
    var agentExitKeys: [UInt8] { [0x05, 0x15, 0x0D] }
    /// 在 tmux 里：tmux 自己就是全屏程序，全屏时也要能开始对话（代价是认不出 tmux 里的 vim）
    var agentWorksInAlternateScreen: Bool { false }
    /// 现在能不能开始和 AI 对话
    var canOpenAgent: Bool { agentWorksInAlternateScreen || !isAlternateScreen() }

    func beginAgentMode(input: @escaping (ArraySlice<UInt8>) -> Void) {
        agentInput = input
    }

    /// redrawPrompt：要不要让 shell 重新显示提示符（在 tmux 的画面里不需要）
    func endAgentMode(redrawPrompt: Bool = true) {
        agentInput = nil
        flushHeld()
        if redrawPrompt, state == .connected, !agentExitKeys.isEmpty { send(agentExitKeys[...]) }
    }

    /// 在终端里显示文字，不经过设备，也不算进带给 AI 的「最近输出」
    func display(_ text: String) {
        deliver(Array(text.utf8)[...])
    }

    private var recentBytes: [UInt8] = []

    /// 最近的终端输出（去掉颜色等控制字符）
    func recentOutput(lines: Int = 40) -> String {
        var text = String(decoding: recentBytes, as: UTF8.self)
        for pattern in [#"\u001B\][^\u0007\u001B]*(\u0007|\u001B\\)?"#, #"\u001B\[[0-?]*[ -/]*[@-~]"#, #"\u001B[@-_]"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\r\n", with: "\n")
        text = String(text.unicodeScalars.filter { $0 == "\n" || $0 == "\t" || $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
        var all = text.split(separator: "\n", omittingEmptySubsequences: false)
        // 最后一行是刚敲的 /xr，不用发
        if let last = all.last, last.contains("/xr") { all.removeLast() }
        return all.suffix(lines)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 影子输入行：在 SSH / 真 shell 里认出 /xr
    // 键盘输入是直接发给远端的，App 看不到「命令」，只能自己记一份正在敲的这一行。
    // 这是尽力而为：用过方向键、Tab 之后这一行就不准了，这时宁可不触发（所以「常用命令」里还有备用入口）。

    /// 小命令行自己处理 /xr，不需要影子行
    var watchesAgentCommand: Bool { !limitedCommands }
    /// 终端视图设置：vim、less 这类全屏程序正在运行（里面的 /xr 是它们的搜索，不能拦）
    var isAlternateScreen: () -> Bool = { false }

    private var shadowLine: [UInt8] = []
    private var shadowUnreliable = false

    /// 用户从键盘输入。不是 /xr 就原样发给 send
    func keyboardInput(_ bytes: ArraySlice<UInt8>) {
        if let agentInput {
            agentInput(bytes)
            return
        }
        guard watchesAgentCommand, AgentSettings.isEnabled else {
            send(bytes)
            return
        }
        var start = bytes.startIndex
        for index in bytes.indices {
            switch bytes[index] {
            case 0x0D, 0x0A:
                if let prompt = shadowAgentPrompt(), canOpenAgent {
                    if start < index { send(bytes[start..<index]) }
                    // Ctrl-U 清掉远端已经显示的这一行，回车不发出去
                    send([0x15][...])
                    resetShadowLine()
                    onAgentRequest?(prompt)
                    let rest = bytes[(index + 1)...]
                    if !rest.isEmpty { keyboardInput(rest) }
                    return
                }
                resetShadowLine()
            case 0x03, 0x04, 0x15:
                resetShadowLine()
            case 0x7F, 0x08:
                // 删掉一个完整的 UTF-8 字符
                while let last = shadowLine.popLast(), last & 0xC0 == 0x80 {}
            case 0x00..<0x20:
                shadowUnreliable = true
            default:
                if shadowLine.count < 4096 { shadowLine.append(bytes[index]) } else { shadowUnreliable = true }
            }
        }
        if start < bytes.endIndex { send(bytes[start...]) }
    }

    private func resetShadowLine() {
        shadowLine = []
        shadowUnreliable = false
    }

    private func shadowAgentPrompt() -> String? {
        guard !shadowUnreliable else { return nil }
        let line = String(decoding: shadowLine, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        if line == "/xr" { return "" }
        guard line.hasPrefix("/xr ") else { return nil }
        return String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
    }
}
