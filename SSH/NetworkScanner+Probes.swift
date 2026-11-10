import Foundation
import Network

/// 对单个 IP 的各种探测：名字（mDNS / NetBIOS / 反向 DNS）、端口指纹、SSH 横幅、22 端口、ping
extension NetworkScanner {
    // MARK: - Resolve hostname (多种方式直接探测这台设备)

    func fillDetails(for device: SSHDevice) async {
        let ip = device.ipAddress
        // 近期探测过就沿用保存的名字、端口和横幅，重复扫描时省掉大部分流量
        if let at = device.detailsAt, Date().timeIntervalSince(at) < Self.detailsTTL,
           !device.hasSSH || device.banner != nil { return }
        let key = "\(ip)|\(device.hasSSH)"
        guard detailsInFlight.insert(key).inserted else { return }
        defer { detailsInFlight.remove(key) }

        // SSH 横幅和名字并行获取，名字拿不到时横幅可以帮助分辨设备类型
        async let bannerResult = device.hasSSH ? readSSHBanner(ip: ip) : nil
        async let portsResult = probePorts(ip: ip)

        if let name = await probeName(ip: ip) {
            setHostname(name, for: ip)
        }
        let banner = await bannerResult
        let ports = await portsResult
        if let index = devices.firstIndex(where: { $0.ipAddress == ip }) {
            if let banner { devices[index].banner = banner }
            devices[index].openPorts = ports
            devices[index].detailsAt = Date()
            persistSoon()
        }
    }

    // MARK: - Device type fingerprint (端口特征)

    private nonisolated static let fingerprintPorts: [UInt16] = [
        53, 80, 139, 443, 445, 548, 554, 631, 5000, 5001, 5555, 8008, 8009, 8080, 8443, 9100, 62078,
    ]

    private nonisolated func probePorts(ip: String) async -> Set<UInt16> {
        await withTaskGroup(of: UInt16?.self) { group in
            for port in Self.fingerprintPorts {
                group.addTask { await self.isPortOpen(ip: ip, port: port) ? port : nil }
            }
            var open: Set<UInt16> = []
            for await port in group {
                if let port { open.insert(port) }
            }
            return open
        }
    }

    private nonisolated func isPortOpen(ip: String, port: UInt16) async -> Bool {
        let connection = NWConnection(host: NWEndpoint.Host(ip),
                                      port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = ResumeOnce { (result: Bool?) in
                connection.cancel()
                continuation.resume(returning: result ?? false)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(true)
                case .failed: once.finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { once.finish(false) }
        }
    }

    /// Bonjour 给出的名字更可靠，已经有的话不会被这里覆盖
    private func setHostname(_ name: String, for ip: String) {
        guard bonjourNames[ip] == nil,
              let index = devices.firstIndex(where: { $0.ipAddress == ip }) else { return }
        devices[index].hostname = name
    }

    /// 依次尝试：Bonjour 已发现的名字 → mDNS 单播反查 → NetBIOS → 反向 DNS
    private func probeName(ip: String) async -> String? {
        if let name = bonjourNames[ip]?.name { return name }
        if let name = await queryMDNSReverse(ip: ip) { return name }
        if let name = await queryNetBIOS(ip: ip) { return name }
        if let name = await resolveHostname(ip: ip), name != ip { return name }
        return nil
    }

    /// 直接向设备的 5353 端口发 mDNS 反向查询，iPhone / Mac 等 Apple 设备会直接回答自己的名字
    private nonisolated func queryMDNSReverse(ip: String) async -> String? {
        let octets = ip.split(separator: ".")
        guard octets.count == 4 else { return nil }
        let qname = octets.reversed().joined(separator: ".") + ".in-addr.arpa"

        var packet: [UInt8] = [0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in qname.split(separator: ".") {
            packet.append(UInt8(label.utf8.count))
            packet.append(contentsOf: label.utf8)
        }
        packet += [0x00, 0x00, 0x0C, 0x00, 0x01]  // PTR, IN

        guard let data = await udpQuery(ip: ip, port: 5353, payload: Data(packet)),
              let name = DNSMessage.firstPTR([UInt8](data)) else { return nil }
        return name.hasSuffix(".") ? String(name.dropLast()) : name
    }

    /// NetBIOS 名称查询（Windows / Samba 设备）
    private nonisolated func queryNetBIOS(ip: String) async -> String? {
        var packet: [UInt8] = [0x12, 0x34, 0x00, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0x20]
        packet += Array("CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".utf8)
        packet += [0x00, 0x00, 0x21, 0x00, 0x01]

        guard let data = await udpQuery(ip: ip, port: 137, payload: Data(packet)) else { return nil }
        let bytes = [UInt8](data)
        guard bytes.count > 57 else { return nil }
        let count = Int(bytes[56])
        for i in 0..<count {
            let start = 57 + i * 18
            guard start + 18 <= bytes.count else { break }
            let isGroup = bytes[start + 16] & 0x80 != 0
            if bytes[start + 15] == 0x00, !isGroup {
                let name = String(decoding: bytes[start..<start + 15], as: UTF8.self)
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { return name }
            }
        }
        return nil
    }

    private nonisolated func udpQuery(ip: String, port: UInt16, payload: Data) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(ip),
                                          port: NWEndpoint.Port(rawValue: port)!, using: .udp)
            let once = ResumeOnce { (data: Data?) in
                connection.cancel()
                continuation.resume(returning: data)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: payload, completion: .contentProcessed { _ in })
                    connection.receiveMessage { data, _, _, _ in once.finish(data) }
                case .failed:
                    once.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.finish(nil) }
        }
    }

    /// 读取 SSH 服务返回的第一行横幅，例如 "SSH-2.0-OpenSSH_9.2"
    private nonisolated func readSSHBanner(ip: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: 22, using: .tcp)
            let once = ResumeOnce { (banner: String?) in
                connection.cancel()
                continuation.resume(returning: banner)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 255) { data, _, _, _ in
                        let line = data.flatMap { String(data: $0, encoding: .utf8) }?
                            .split(whereSeparator: \.isNewline).first.map(String.init)
                        once.finish(line)
                    }
                case .failed:
                    once.finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { once.finish(nil) }
        }
    }

    private nonisolated func resolveHostname(ip: String) async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            DispatchQueue.global().async {
                var addr = sockaddr_in()
                addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                addr.sin_family = sa_family_t(AF_INET)
                guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else {
                    continuation.resume(returning: nil)
                    return
                }

                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let result = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size),
                                    &host, socklen_t(host.count),
                                    nil, 0, NI_NAMEREQD)
                    }
                }
                continuation.resume(returning: result == 0 ? String(cString: host) : nil)
            }
        }
    }

    // MARK: - Check if SSH port is open on a single IP

    nonisolated func probeHost(ip: String, timeout: Double = 1.0) async -> HostProbe {
        let connection = NWConnection(host: NWEndpoint.Host(ip), port: 22, using: .tcp)

        return await withCheckedContinuation { (continuation: CheckedContinuation<HostProbe, Never>) in
            let once = ResumeOnce { (result: HostProbe?) in
                connection.cancel()
                continuation.resume(returning: result ?? .silent)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.finish(.ssh)
                case .waiting(let error), .failed(let error):
                    // 连接被拒绝（RST）也说明对方在线，只是没开 22 端口
                    if case .posix(let code) = error, code == .ECONNREFUSED {
                        once.finish(.reachable)
                    } else if case .failed = state {
                        once.finish(.silent)
                    }
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { once.finish(.silent) }
        }
    }

    // MARK: - Ping sweep (ICMP)

    nonisolated func pingSweep(_ ips: [String]) async -> Set<String> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Set<String>, Never>) in
            DispatchQueue.global().async {
                continuation.resume(returning: ICMPPinger.sweep(ips))
            }
        }
    }
}
