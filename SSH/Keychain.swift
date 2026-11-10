import Foundation
import Security

/// 把 SSH 密码和免密登录的私钥存在系统钥匙串里，按 "用户名@主机:端口" 区分
enum Keychain {
    private static let service = "thexyrith.SSH.password"
    private static let keyService = "thexyrith.SSH.key"

    private static func query(_ account: String, service: String = service) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func account(user: String, host: String, port: Int) -> String {
        "\(user)@\(host):\(port)"
    }

    private static func read(_ account: String, service: String) -> Data? {
        var request = query(account, service: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func write(_ data: Data, account: String, service: String) {
        let update = [kSecValueData as String: data]
        if SecItemUpdate(query(account, service: service) as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = query(account, service: service)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - 密码

    static func password(for account: String) -> String? {
        read(account, service: service).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func save(_ password: String, for account: String) {
        write(Data(password.utf8), account: account, service: service)
        keysChanged()
    }

    /// 删除这个 App 保存的所有 SSH 密码
    static func deleteAll() {
        let all: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(all as CFDictionary)
        keysChanged()
    }

    static func delete(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
        keysChanged()
    }

    // MARK: - 免密登录的私钥

    static func privateKey(for account: String) -> Data? {
        read(account, service: keyService)
    }

    static func savePrivateKey(_ data: Data, for account: String) {
        write(data, account: account, service: keyService)
        keysChanged()
    }

    static func deletePrivateKey(_ account: String) {
        SecItemDelete(query(account, service: keyService) as CFDictionary)
        keysChanged()
    }

    static func deleteAllPrivateKeys() {
        let all: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyService,
        ]
        SecItemDelete(all as CFDictionary)
        keysChanged()
    }

    // MARK: - Agent 的 API Key

    private static let agentService = "thexyrith.SSH.agentKey"
    private static let agentAccount = "default"

    static func agentAPIKey() -> String? {
        read(agentAccount, service: agentService).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func saveAgentAPIKey(_ key: String) {
        write(Data(key.utf8), account: agentAccount, service: agentService)
    }

    static func deleteAgentAPIKey() {
        SecItemDelete(query(agentAccount, service: agentService) as CFDictionary)
    }

    private static func accounts(service: String) -> [String] {
        var request: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        request[kSecReturnData as String] = false
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// 设置过免密登录（存了私钥）的账户（"用户名@主机:端口"）
    static func keyAccounts() -> [String] {
        accounts(service: keyService)
    }

    /// 设置过免密登录的主机地址集合，设备列表用它来显示五角星
    static func keyHosts() -> Set<String> {
        Set(keyAccounts().compactMap { parse($0)?.host })
    }

    static func parse(_ account: String) -> (user: String, host: String, port: Int)? {
        guard let at = account.firstIndex(of: "@"), let colon = account.lastIndex(of: ":"), at < colon,
              let port = Int(account[account.index(after: colon)...]) else { return nil }
        return (String(account[..<at]), String(account[account.index(after: at)..<colon]), port)
    }

    /// 通知界面（设备列表）保存的登录信息有变化，需要刷新五角星
    private static func keysChanged() {
        let defaults = UserDefaults.standard
        defaults.set(defaults.integer(forKey: SettingsKey.keyRevision) + 1, forKey: SettingsKey.keyRevision)
    }
}
