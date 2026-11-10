import Foundation

/// 设置项和其他保存的数据用的存储键，用到的地方都从这里取，避免写错
enum SettingsKey {
    static let terminalFontSize = "terminalFontSize"
    static let preferRealShell = "preferRealShell"
    static let autoScan = "autoScan"
    /// 点没开 SSH 的设备时，是否显示「怎么开 SSH」引导
    static let sshGuide = "showSSHGuide"
    /// 切到后台被断开后，回到前台是否自动重连
    static let autoReconnect = "autoReconnect"
    /// SSH 连上后自动进入 tmux，断线重连后接回原来的内容
    static let tmuxResume = "tmuxResume"
    /// 设备页长按菜单里的「打开网页」「网络唤醒」
    static let deviceTools = "deviceTools"
    /// 设备页显示常用连接
    static let savedConnectionsEnabled = "savedConnectionsEnabled"
    /// 常用连接的内容（JSON）
    static let savedConnections = "savedConnections"
    /// 已记住的主机密钥：["主机:端口": "公钥"]
    static let knownHosts = "knownHosts"
    /// 免密登录的私钥有增减时加一，让设备列表刷新五角星
    static let keyRevision = "keyRevision"
    /// AI 助手总开关（默认关，关着不会发任何请求）
    static let agentEnabled = "agentEnabled"
    /// 发给 AI 时默认带上最近的终端输出
    static let agentIncludeOutput = "agentIncludeOutput"
    /// 退出对话后保留，下次 /xr 接着聊
    static let agentKeepConversation = "agentKeepConversation"
    /// Agent 用的 AI 接口地址和模型名（Key 在钥匙串里）
    static let agentBaseURL = "agentBaseURL"
    static let agentModel = "agentModel"

    static let defaultFontSize = 14.0

    /// 读开关；没设置过就用 fallback
    static func bool(_ key: String, fallback: Bool = true) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    static var knownHostKeys: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: knownHosts) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: knownHosts) }
    }
}

/// App 自己的文件夹（在"文件"App 里能看到）
enum AppFolders {
    static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 传文件下载的东西放在这里
    static var downloads: URL {
        documents.appendingPathComponent("Downloads", isDirectory: true)
    }
}

/// 接口地址、模型名存 UserDefaults，Key 只存钥匙串
enum AgentSettings {
    static var isEnabled: Bool { SettingsKey.bool(SettingsKey.agentEnabled, fallback: false) }
    static var includeOutput: Bool { SettingsKey.bool(SettingsKey.agentIncludeOutput, fallback: true) }
    static var keepConversation: Bool { SettingsKey.bool(SettingsKey.agentKeepConversation, fallback: false) }

    static var baseURL: String {
        get { UserDefaults.standard.string(forKey: SettingsKey.agentBaseURL) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.agentBaseURL) }
    }

    static var model: String {
        get { UserDefaults.standard.string(forKey: SettingsKey.agentModel) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.agentModel) }
    }

    static var apiKey: String? {
        #if DEBUG
        // 模拟器里不签名的版本用不了钥匙串，调试时用假 Key 走流程；正式包里没有这段
        if let demo = UserDefaults.standard.string(forKey: "xrshDemoAgentKey") { return demo }
        #endif
        return Keychain.agentAPIKey()
    }

    static var client: AgentClient? {
        guard !baseURL.isEmpty, !model.isEmpty, let apiKey, !apiKey.isEmpty else { return nil }
        return AgentClient(baseURL: baseURL, model: model, apiKey: apiKey)
    }
}
