import Foundation

#if DEBUG
/// 只在调试版里：README 截图用的演示会话，显示一段预设的 SSH 输出，不会连任何设备
@MainActor
final class DemoSession: TerminalSession {
    override var title: String { "pi@raspberrypi.local" }
    override var reconnectHost: String? { "192.168.1.23" }

    override init() {
        super.init()
        state = .connected
        let g = "\u{1B}[1;32m", b = "\u{1B}[1;34m", d = "\u{1B}[2m", r = "\u{1B}[0m"
        let prompt = "\(g)pi@raspberrypi\(r):\(b)~\(r)$ "
        let lines = [
            "\(d)Linux raspberrypi 6.6.20 aarch64\(r)",
            "\(d)Last login: Tue Nov  4 16:40:12\(r)",
            "",
            prompt + "uname -a",
            "Linux raspberrypi 6.6.20 aarch64 GNU/Linux",
            prompt + "uptime",
            " 16:41:02 up 12 days,  3:24,  load 0.08",
            prompt + "df -h /",
            "Filesystem  Size  Used Avail Use% Mounted",
            "/dev/root    29G  6.1G   22G  22% /",
            prompt + "ls",
            "\(b)Documents\(r)  \(b)projects\(r)  \(b)scripts\(r)  notes.txt",
        ]
        receive(Array((lines.joined(separator: "\r\n") + "\r\n").utf8)[...])
        if UserDefaults.standard.bool(forKey: "xrshDemoAlt") {
            // 模拟 tmux 的全屏画面
            receive(Array("\u{1B}[?1049h\u{1B}[2J\u{1B}[H[tmux screen] demo\r\n$ ".utf8)[...])
        }
    }

    // 把输入原样显示出来，方便在模拟器里看键盘发了什么
    override func send(_ bytes: ArraySlice<UInt8>) { receive(bytes) }
    override var agentWorksInAlternateScreen: Bool { UserDefaults.standard.bool(forKey: "xrshDemoAlt") }
    override func resize(cols: Int, rows: Int) {}
    override func close() { state = .closed }

    override var canRunCommands: Bool { true }
    override func runCommand(_ command: String, timeout: TimeInterval) async throws -> RemoteCommandResult {
        try await Task.sleep(for: .seconds(1))
        if command.contains("app.conf") {
            return RemoteCommandResult(output: "name: pi\nAPI_TOKEN=abc123", exitCode: 0)
        }
        return RemoteCommandResult(
            output: "Filesystem  Size  Used Avail Use% Mounted\n/dev/root    29G  6.1G   22G  22% /",
            exitCode: 0
        )
    }
}
#endif
