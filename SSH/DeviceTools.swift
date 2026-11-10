import Darwin
import Foundation

/// 设备页长按菜单里的小工具：打开网页、网络唤醒
nonisolated enum DeviceTools {
    /// 这台设备的网页地址。优先 80，很多设备会自己跳到 https
    static func webURL(for device: SSHDevice) -> URL? {
        let choices: [(port: UInt16, scheme: String)] = [
            (80, "http"), (443, "https"), (8080, "http"), (8443, "https"), (5000, "http"), (5001, "https"),
        ]
        guard let pick = choices.first(where: { device.openPorts.contains($0.port) }) else { return nil }
        let isDefault = pick.port == 80 || pick.port == 443
        return URL(string: "\(pick.scheme)://\(device.ipAddress)" + (isDefault ? "" : ":\(pick.port)"))
    }

    // MARK: - MAC 地址（按 IP 保存）

    private static let macKey = "deviceMACs"

    static func savedMAC(for ip: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: macKey) as? [String: String])?[ip]
    }

    static func saveMAC(_ mac: String, for ip: String) {
        var all = UserDefaults.standard.dictionary(forKey: macKey) as? [String: String] ?? [:]
        all[ip] = mac
        UserDefaults.standard.set(all, forKey: macKey)
    }

    /// 统一成 aa:bb:cc:dd:ee:ff；接受 - 分隔、没有分隔符和 arp 省略前导 0 的写法。不合法返回 nil
    static func normalizeMAC(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "-", with: ":")
        var parts = trimmed.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1, trimmed.count == 12 {
            parts = stride(from: 0, to: 12, by: 2).map { offset in
                let start = trimmed.index(trimmed.startIndex, offsetBy: offset)
                return String(trimmed[start..<trimmed.index(start, offsetBy: 2)])
            }
        }
        guard parts.count == 6 else { return nil }
        var bytes: [String] = []
        for part in parts {
            guard (1...2).contains(part.count), UInt8(part, radix: 16) != nil else { return nil }
            bytes.append(part.count == 1 ? "0" + part : part)
        }
        return bytes.joined(separator: ":")
    }

    /// 查系统的 ARP 表。普通 App 没有权限，越狱版才查得到；查不到让用户自己填
    static func lookUpMAC(ip: String) async -> String? {
        guard let launch = PTYSession.detect() else { return nil }
        let bin = ["/usr/sbin", "/usr/bin", "/sbin", "/bin"]
        let path = (launch.jbroot.map { root in bin.map { root + $0 } } ?? []) + bin
        guard let result = try? await LocalCommand.run(
            "arp -n \(ip)",
            shell: launch.shell,
            environment: ["PATH=" + path.joined(separator: ":")],
            directory: "/",
            timeout: 3
        ) else { return nil }
        let pattern = #"([0-9a-fA-F]{1,2}:){5}[0-9a-fA-F]{1,2}"#
        return result.output.range(of: pattern, options: .regularExpression).flatMap { normalizeMAC(String(result.output[$0])) }
    }

    // MARK: - 网络唤醒

    /// 魔术包：6 个 FF，再把 MAC 重复 16 次
    static func wakePacket(mac: String) -> [UInt8] {
        let bytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        return [UInt8](repeating: 0xFF, count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 }
    }

    /// 发给网段广播、全网广播和设备本身。返回有没有发出去；对方醒没醒是不知道的
    static func wake(mac: String, ip: String, localIP: String?, mask: String?) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))

        var targets = ["255.255.255.255", ip]
        if let localIP, let mask {
            let host = inet_addr(localIP), netmask = inet_addr(mask)
            if host != INADDR_NONE {
                let address = in_addr(s_addr: host | ~netmask)
                targets.insert(String(cString: inet_ntoa(address)), at: 0)
            }
        }

        let packet = wakePacket(mac: mac)
        var sent = false
        for target in targets {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = in_port_t(9).bigEndian
            address.sin_addr.s_addr = inet_addr(target)
            let count = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if count == packet.count { sent = true }
        }
        return sent
    }
}
