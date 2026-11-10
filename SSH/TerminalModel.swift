import Combine
import Crypto
import Foundation
import UIKit

/// 终端页的状态：当前会话，以及"新建连接"面板的开关
@MainActor
final class TerminalModel: ObservableObject {
    @Published var session: TerminalSession? {
        didSet {
            session?.onAgentRequest = { [weak self] prompt in
                self?.openAgent(prompt: prompt)
            }
            if let agentTerminal, session !== oldValue {
                // AI 切换设备时对话跟过去；用户自己换了连接就结束对话
                if agentSwitching, let session {
                    agentTerminal.move(to: session)
                } else {
                    agentTerminal.end()
                }
            }
            // 会话状态变了（连上、断开）也要刷新终端页的工具栏
            sessionChange = session?.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
                // 状态更新完之后，看看是不是在后台被断开的
                DispatchQueue.main.async {
                    self?.endAgentIfDisconnected()
                    self?.rememberOrForgetSession()
                    self?.reconnectIfDropped()
                }
            }
        }
    }
    private var sessionChange: AnyCancellable?
    @Published var showConnect = false
    @Published var prefillHost = ""
    @Published var prefillUser = ""
    @Published var prefillPort = 22

    struct AgentRequest: Identifiable {
        let id = UUID()
        let prompt: String
    }

    /// 不为 nil 时弹出「连接 AI」，填好后接着打开对话
    @Published var agentSetup: AgentRequest?
    /// 正在进行的终端内对话
    var agentTerminal: AgentTerminal?
    var agentSwitching = false
    /// 「保留 AI 对话」打开时留着的对话
    var savedAgent: AgentSession?

    weak var scanner: NetworkScanner?

    // MARK: - 断线自动重连
    // App 切到后台后，系统会悄悄掐掉 SSH 连接。回到前台时如果发现是这样断的，
    // 就自动用密钥（或保存的密码）重连一次；自己输入 exit 退出的不会重连。
    private var inBackground = false
    private var resumeWindowEnd = Date.distantPast
    private var retriedThisTrip = false
    private var lifecycle: [AnyCancellable] = []

    init(scanner: NetworkScanner) {
        self.scanner = scanner
        let center = NotificationCenter.default
        lifecycle = [
            center.publisher(for: UIApplication.didEnterBackgroundNotification).sink { [weak self] _ in
                self?.inBackground = true
                self?.retriedThisTrip = false
            },
            center.publisher(for: UIApplication.willEnterForegroundNotification).sink { [weak self] _ in
                guard let self else { return }
                // 回到前台后几秒内发现的断线，算作在后台断的
                resumeWindowEnd = Date().addingTimeInterval(8)
                reconnectIfDropped()
            },
            center.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in
                self?.inBackground = false
            },
        ]
    }

    // MARK: - 大退后再打开，接回上次的连接
    private static let lastSessionKey = "lastSSHSession"

    /// 连上了就记住是哪台设备；自己退出（exit）或点「断开」就忘掉，下次打开不再自动连
    private func rememberOrForgetSession() {
        guard let ssh = session as? SSHSession else { return }
        switch ssh.state {
        case .connected:
            UserDefaults.standard.set(ssh.keyAccount, forKey: Self.lastSessionKey)
        case .closed, .failed:
            if !inBackground && Date() >= resumeWindowEnd {
                UserDefaults.standard.removeObject(forKey: Self.lastSessionKey)
            }
        default: break
        }
    }

    /// 打开 App 时调用：上次是连着一台设备退出的，并且有密钥或保存的密码，就自动连上。返回有没有连
    @discardableResult
    func resumeLastSession() -> Bool {
        #if DEBUG
        // 截图用：直接进入演示终端
        if UserDefaults.standard.bool(forKey: "xrshDemoTerminal") {
            session = DemoSession()
            return true
        }
        #endif
        guard session == nil,
              let account = UserDefaults.standard.string(forKey: Self.lastSessionKey),
              let parsed = Keychain.parse(account) else { return false }
        let password = Keychain.password(for: account)
        guard Keychain.privateKey(for: account) != nil || password != nil else { return false }
        start(host: parsed.host, port: parsed.port, username: parsed.user, password: password ?? "")
        return true
    }

    private func reconnectIfDropped() {
        guard SettingsKey.bool(SettingsKey.autoReconnect, fallback: false), !retriedThisTrip, inBackground || Date() < resumeWindowEnd,
              let ssh = session as? SSHSession else { return }
        switch ssh.state {
        case .closed, .failed: break
        default: return
        }
        let account = ssh.keyAccount
        let password = Keychain.password(for: account)
        // 既没有密钥也没有保存的密码，就不替用户瞎试，留着「重新连接」按钮
        guard ssh.hasKeyLogin || password != nil else { return }
        retriedThisTrip = true
        start(host: ssh.host, port: ssh.port, username: ssh.username, password: password ?? "")
    }

    func requestConnect(host: String, user: String = "", port: Int = 22) {
        prefillHost = host
        prefillUser = user
        prefillPort = port
        showConnect = true
    }

    /// 点设备直接进入：这台设备设置过免密登录（有密钥）就直接连，没有才弹出填写面板
    func connectQuick(host: String, port: Int = 22) {
        let saved = Keychain.keyAccounts().compactMap(Keychain.parse).filter { $0.host == host && $0.port == port }
        let last = UserDefaults.standard.string(forKey: "lastSSHUser")
        guard let pick = saved.first(where: { $0.user == last }) ?? saved.first else {
            requestConnect(host: host, port: port)
            return
        }
        let account = Keychain.account(user: pick.user, host: host, port: port)
        start(host: host, port: port, username: pick.user, password: Keychain.password(for: account) ?? "")
    }

    /// 打开本机终端：能启动真 shell（越狱环境）就用真的，否则用 App 自带的小命令行
    func startLocal() {
        session?.close()
        if SettingsKey.bool(SettingsKey.preferRealShell), let real = PTYSession(cols: 80, rows: 24) {
            session = real
            return
        }
        let shell = LocalShell()
        shell.devices = { [weak scanner] in scanner?.devices ?? [] }
        shell.startScan = { [weak scanner] in scanner?.startScan() }
        shell.openSSH = { [weak self] host, port, user in
            self?.requestConnect(host: host, user: user ?? "", port: port)
        }
        shell.openAgent = { [weak self] prompt in
            self?.openAgent(prompt: prompt)
        }
        session = LocalSession(shell: shell, notice: PTYSession.lastFailure)
    }

    func start(host: String, port: Int, username: String, password: String, useKey: Bool = true) {
        session?.close()
        let session = SSHSession(host: host, port: port, username: username)
        self.session = session
        let key = Keychain.privateKey(for: session.keyAccount)
            .flatMap { try? Curve25519.Signing.PrivateKey(rawRepresentation: $0) }
        session.connect(password: password, key: useKey ? key : nil)
    }

    /// 点常用连接：有密钥或保存的密码就直接连，没有才弹出填写面板
    func connectSaved(_ connection: SavedConnection) {
        let account = Keychain.account(user: connection.user, host: connection.host, port: connection.port)
        let password = Keychain.password(for: account)
        if Keychain.privateKey(for: account) != nil || password != nil {
            start(host: connection.host, port: connection.port, username: connection.user, password: password ?? "")
        } else {
            requestConnect(host: connection.host, user: connection.user, port: connection.port)
        }
    }

    func disconnect() {
        savedAgent = nil
        UserDefaults.standard.removeObject(forKey: Self.lastSessionKey)
        session?.close()
        session = nil
    }
}
