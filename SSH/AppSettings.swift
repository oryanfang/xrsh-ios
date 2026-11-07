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
    /// 已记住的主机密钥：["主机:端口": "公钥"]
    static let knownHosts = "knownHosts"
    /// 免密登录的私钥有增减时加一，让设备列表刷新五角星
    static let keyRevision = "keyRevision"

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
