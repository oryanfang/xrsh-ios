import Foundation

/// 终端页和 AI 助手之间的部分：开始对话、给 AI 看设备列表、替 AI 切换设备
extension TerminalModel {
    /// 给 agent 看的设备列表：不含密码和密钥，只说有没有设置过免密
    func agentDeviceList() -> String {
        let keyHosts = Keychain.keyHosts()
        let lines = (scanner?.devices ?? []).sorted { $0.sortKey < $1.sortKey }.map { device in
            [
                device.ipAddress,
                device.displayName.map { "name=\($0)" },
                device.deviceType.map { "type=\($0.name)" },
                "ssh=\(device.hasSSH ? "yes" : "no")",
                "passwordless=\(keyHosts.contains(device.ipAddress) ? "yes" : "no")",
                device.isOffline ? "offline" : nil,
            ].compactMap { $0 }.joined(separator: " ")
        }
        return lines.isEmpty ? "No devices found yet." : lines.joined(separator: "\n")
    }

    /// /xr：在终端里开始对话；还没填接口就先弹设置
    func openAgent(prompt: String) {
        guard agentTerminal == nil, let session else { return }
        guard let client = AgentSettings.client else {
            agentSetup = AgentRequest(prompt: prompt)
            return
        }
        agentTerminal = AgentTerminal(agent: agentSession(client: client), session: session, prompt: prompt) { [weak self] in
            self?.agentTerminal = nil
        }
        session.requestFocus()
    }

    func endAgentIfDisconnected() {
        switch session?.state {
        case .closed, .failed: agentTerminal?.end()
        default: break
        }
    }

    /// 拿一个 agent 对话：开了「保留 AI 对话」就接着上次的（改过接口设置的除外）
    func agentSession(client: AgentClient) -> AgentSession {
        if AgentSettings.keepConversation, let savedAgent, savedAgent.client == client { return savedAgent }
        let agent = AgentSession(client: client, model: self)
        savedAgent = AgentSettings.keepConversation ? agent : nil
        return agent
    }

    enum AgentConnectResult {
        case connected(String)
        case noPasswordlessLogin
        case failed(String)
    }

    /// AI 的 connect 工具：只连设置过免密登录的设备，碰不到密码
    func agentConnect(host: String, user: String?) async -> AgentConnectResult {
        #if DEBUG
        // 模拟器里用不了钥匙串：演示模式下假装连上，用来看面板会不会跟着消失
        if UserDefaults.standard.bool(forKey: "xrshDemoTerminal") {
            session?.close()
            let demo = DemoSession()
            agentSwitching = true
            session = demo
            agentSwitching = false
            return .connected(demo.title)
        }
        #endif
        let saved = Keychain.keyAccounts().compactMap(Keychain.parse).filter {
            $0.host.lowercased() == host.lowercased() && (user == nil || $0.user == user)
        }
        guard let pick = saved.first else { return .noPasswordlessLogin }
        // 只用密钥，不用保存的密码
        agentSwitching = true
        start(host: pick.host, port: pick.port, username: pick.user, password: "")
        agentSwitching = false
        guard let current = session else { return .failed("") }
        let deadline = Date().addingTimeInterval(15)
        while current.state == .connecting, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        switch current.state {
        case .connected: return .connected(current.title)
        case .failed(let message): return .failed(message)
        case .connecting: return .failed(tr("连接超时，请确认设备在线并且开着 SSH。"))
        case .closed: return .failed(tr("连接已断开"))
        }
    }
}
