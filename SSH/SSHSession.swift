import Citadel
import Combine
import Crypto
import Foundation
import NIO
import NIOSSH

/// 首次连接时记住主机密钥，之后密钥变了就拒绝连接（类似 ssh 的 known_hosts）
private struct KnownHostsValidator: NIOSSHClientServerAuthenticationDelegate {
    struct HostKeyChanged: LocalizedError {
        var errorDescription: String? { tr("这台设备的主机密钥和上次不一样，可能是重装了系统，也可能有人在冒充它。已拒绝连接。") }
    }

    let hostID: String

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let key = String(openSSHPublicKey: hostKey)
        var known = SettingsKey.knownHostKeys
        if let saved = known[hostID] {
            if saved == key {
                validationCompletePromise.succeed(())
            } else {
                validationCompletePromise.fail(HostKeyChanged())
            }
        } else {
            known[hostID] = key
            SettingsKey.knownHostKeys = known
            validationCompletePromise.succeed(())
        }
    }
}

/// 一次 SSH 终端会话：负责连接、把远端输出交给终端视图、把键盘输入发给远端
@MainActor
final class SSHSession: TerminalSession {
    let host: String
    let port: Int
    let username: String

    override var title: String { "\(username)@\(host)" }
    override var reconnectHost: String? { host }

    private var client: SSHClient?
    private var writer: TTYStdinWriter?
    private var task: Task<Void, Never>?
    private let wrapsInTmux = SettingsKey.bool(SettingsKey.tmuxResume, fallback: false)
    private var tmuxStarted = false
    private var cols = 80
    private var rows = 24

    init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
        super.init()
    }

    /// 优先用私钥登录；私钥登不上而又填了密码时，退回用密码
    func connect(password: String, key: Curve25519.Signing.PrivateKey? = nil) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await self.openClient(password: password, key: key)
                self.client = client
                client.onDisconnect { [weak self] in
                    let session = self
                    Task { @MainActor in session?.finish(error: nil) }
                }

                let request = SSHChannelRequestEvent.PseudoTerminalRequest(
                    wantReply: true,
                    term: "xterm-256color",
                    terminalCharacterWidth: cols,
                    terminalRowHeight: rows,
                    terminalPixelWidth: 0,
                    terminalPixelHeight: 0,
                    terminalModes: SSHTerminalModes([:])
                )
                // 像电脑上的 ssh 一样把语言带过去，否则对方没配语言时中文会乱码。
                // 对方不接受也没关系，不等回复，不影响连接
                let locale = SSHChannelRequestEvent.EnvironmentRequest(wantReply: false, name: "LANG", value: "C.UTF-8")
                try await client.withPTY(request, environment: [locale]) { inbound, outbound in
                    self.attach(outbound)
                    for try await output in inbound {
                        switch output {
                        case .stdout(let buffer), .stderr(let buffer):
                            self.receive(Array(buffer.readableBytesView)[...])
                            self.startTmuxIfNeeded()
                        }
                    }
                }
                finish(error: nil)
            } catch {
                finish(error: error)
            }
        }
    }

    override var agentWorksInAlternateScreen: Bool { wrapsInTmux }

    /// 等 shell 有输出了再敲。-A：已有这个会话就接回去。对方没装 tmux 就什么也不做，留在普通 shell
    /// 开头的空格让这条命令不进历史；-u 让 tmux 按 UTF-8 显示中文
    private func startTmuxIfNeeded() {
        guard wrapsInTmux, !tmuxStarted else { return }
        tmuxStarted = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            let command = " [ -z \"$TMUX\" ] && command -v tmux >/dev/null 2>&1 && tmux -u new-session -A -s xrsh\r"
            self?.send(Array(command.utf8)[...])
        }
    }

    // MARK: - 密钥登录

    private struct KeyLoginFailed: LocalizedError {
        var errorDescription: String? { tr("公钥已经写进对方设备，但用密钥登录没有成功（对方可能不允许密钥登录），所以没有保存密钥。") }
    }

    var keyAccount: String { Keychain.account(user: username, host: host, port: port) }

    var hasKeyLogin: Bool { Keychain.privateKey(for: keyAccount) != nil }

    private static func connectClient(host: String, port: Int, auth: SSHAuthenticationMethod) async throws -> SSHClient {
        try await SSHClient.connect(
            host: host,
            port: port,
            authenticationMethod: auth,
            hostKeyValidator: .custom(KnownHostsValidator(hostID: "\(host):\(port)")),
            reconnect: .never,
            connectTimeout: .seconds(10)
        )
    }

    private func openClient(password: String, key: Curve25519.Signing.PrivateKey?) async throws -> SSHClient {
        if let key {
            do {
                return try await Self.connectClient(host: host, port: port, auth: .ed25519(username: username, privateKey: key))
            } catch {
                if password.isEmpty { throw error }
            }
        }
        return try await Self.connectClient(host: host, port: port, auth: .passwordBased(username: username, password: password))
    }

    /// 设置免密登录：生成一把密钥，把公钥加到对方的 ~/.ssh/authorized_keys，
    /// 确认能用密钥登录之后，才把私钥存进钥匙串
    func enableKeyLogin() async throws {
        guard let client else {
            throw NSError(domain: "SSH", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("还没有连上设备")])
        }
        let key = Curve25519.Signing.PrivateKey()
        let line = String(openSSHPublicKey: NIOSSHPrivateKey(ed25519Key: key).publicKey) + " xr-ssh-scanner"
        let file = "~/.ssh/authorized_keys"
        let command = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch \(file) && chmod 600 \(file) && "
            + "{ grep -qxF '\(line)' \(file) || printf '\\n%s\\n' '\(line)' >> \(file); }"
        _ = try await client.executeCommand(command)

        do {
            let check = try await Self.connectClient(host: host, port: port, auth: .ed25519(username: username, privateKey: key))
            try? await check.close()
        } catch {
            throw KeyLoginFailed()
        }
        Keychain.savePrivateKey(key.rawRepresentation, for: keyAccount)
    }

    private func attach(_ writer: TTYStdinWriter) {
        self.writer = writer
        state = .connected
        // 连接建立时终端视图可能已经量好了大小，补发一次
        resize(cols: cols, rows: rows)
    }

    private func finish(error: Error?) {
        guard state != .closed else { return }
        if let error {
            state = .failed(Self.describe(error, host: host))
        } else if case .failed = state {
            return
        } else {
            state = .closed
        }
        writer = nil
    }

    /// 在同一个 SSH 连接上再开一条文件传输（SFTP）通道
    func openSFTP() async throws -> SFTPClient {
        guard let client else {
            throw NSError(domain: "SSH", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("还没有连上设备")])
        }
        return try await client.openSFTP()
    }

    override var canRunCommands: Bool { state == .connected }

    override func runCommand(_ command: String, timeout: TimeInterval) async throws -> RemoteCommandResult {
        guard let client else {
            throw NSError(domain: "SSH", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("还没有连上设备")])
        }
        return try await RemoteCommand.run(command, on: client, timeout: timeout)
    }

    override func send(_ bytes: ArraySlice<UInt8>) {
        guard let writer else { return }
        let buffer = ByteBuffer(bytes: bytes)
        Task { try? await writer.write(buffer) }
    }

    override func resize(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        guard let writer else { return }
        Task { try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0) }
    }

    override func close() {
        task?.cancel()
        let client = client
        Task { try? await client?.close() }
        writer = nil
        if state == .connecting || state == .connected { state = .closed }
    }

    private static func describe(_ error: Error, host: String) -> String {
        let local = host == "127.0.0.1" || host == "localhost"
        if let error = error as? LocalizedError, let text = error.errorDescription { return text }
        let text = String(describing: error)
        if text.contains("allAuthenticationOptionsFailed") { return tr("用户名或密码不对，或者这台设备不允许密码登录。") }
        if text.contains("connectTimeout") || text.contains("timeout") { return tr("连接超时，请确认设备在线并且开着 SSH。") }
        if text.contains("Connection refused") || text.contains("connectionRefused") {
            return local ? tr("这台手机上没有运行 SSH 服务。需要先在越狱的手机上安装并启动 OpenSSH。") : tr("对方拒绝了连接，没有开 SSH 服务。")
        }
        return text
    }
}
