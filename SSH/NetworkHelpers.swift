import Foundation

/// 用一个非特权 ICMP socket 向所有地址发 echo 请求，收集回应的地址
nonisolated enum ICMPPinger {
    static func sweep(_ ips: [String]) -> Set<String> {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return [] }
        defer { close(fd) }
        // 非阻塞，避免发往未解析 ARP 的地址时 sendto 一直卡住
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var alive: Set<String> = []
        // 发两轮，减少丢包造成的漏报
        for round in 0..<2 {
            for ip in ips where !alive.contains(ip) {
                send(fd, to: ip, sequence: UInt16(round))
            }
            collect(fd, into: &alive, seconds: round == 0 ? 1.0 : 1.5)
        }
        return alive
    }

    private static func send(_ fd: Int32, to ip: String, sequence: UInt16) {
        var packet = [UInt8](repeating: 0, count: 16)
        packet[0] = 8  // echo request
        packet[4] = 0x53; packet[5] = 0x53  // identifier
        packet[6] = UInt8(sequence >> 8); packet[7] = UInt8(sequence & 0xFF)
        let sum = checksum(packet)
        packet[2] = UInt8(sum >> 8); packet[3] = UInt8(sum & 0xFF)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return }
        for _ in 0..<2 {
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            // 发送缓冲区满了就稍等一下再试一次，仍失败就放弃这个地址
            guard result < 0, errno == EAGAIN || errno == ENOBUFS else { return }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&pfd, 1, 20)
        }
    }

    private static func collect(_ fd: Int32, into alive: inout Set<String>, seconds: Double) {
        let deadline = Date().addingTimeInterval(seconds)
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            if remaining <= 0 { return }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, remaining) > 0 else { return }

            var src = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &src) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, &buffer, buffer.count, 0, $0, &len)
                }
            }
            guard count > 0 else { continue }

            // 回应可能带 IP 头，先跳过
            var offset = 0
            if buffer[0] >> 4 == 4 { offset = Int(buffer[0] & 0x0F) * 4 }
            guard count > offset, buffer[offset] == 0 else { continue }  // 0 = echo reply

            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &src.sin_addr, &text, socklen_t(text.count))
            alive.insert(String(cString: text))
        }
    }

    /// ICMP 报文的校验和（ping 命令也用这个）
    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum & 0xFFFF)
    }
}

/// 解析一个 Bonjour 服务的所有 IPv4 地址
final class ServiceResolver: NSObject, NetServiceDelegate {
    private let service: NetService
    var onResolved: (([String]) -> Void)?

    init(name: String, type: String, domain: String) {
        service = NetService(domain: domain, type: type, name: name)
        super.init()
        service.delegate = self
    }

    func start() {
        service.resolve(withTimeout: 5)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        var ips: [String] = []
        for data in sender.addresses ?? [] {
            data.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                let sa = base.assumingMemoryBound(to: sockaddr.self)
                guard sa.pointee.sa_family == UInt8(AF_INET) else { return }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(data.count), &host, socklen_t(host.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    ips.append(String(cString: host))
                }
            }
        }
        // NetService 往往只给出一个接口上的地址，再按主机名查一遍拿到全部 IPv4 地址
        guard let hostName = sender.hostName else {
            onResolved?(ips)
            return
        }
        DispatchQueue.global().async { [onResolved] in
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            if getaddrinfo(hostName, nil, &hints, &result) == 0 {
                var cursor = result
                while let info = cursor {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen,
                                   &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        ips.append(String(cString: host))
                    }
                    cursor = info.pointee.ai_next
                }
                freeaddrinfo(result)
            }
            onResolved?(Array(Set(ips)))
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {}
}

/// 保证 continuation 只被恢复一次
nonisolated final class ResumeOnce<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private let action: (Value?) -> Void

    init(_ action: @escaping (Value?) -> Void) { self.action = action }

    func finish(_ value: Value?) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        action(value)
    }
}

/// 最小的 DNS 报文解析：只取第一条 PTR 记录的名字
nonisolated enum DNSMessage {
    static func firstPTR(_ d: [UInt8]) -> String? {
        guard d.count > 12 else { return nil }
        let questions = Int(d[4]) << 8 | Int(d[5])
        let answers = Int(d[6]) << 8 | Int(d[7])
        var pos = 12
        for _ in 0..<questions {
            guard let next = skipName(d, pos) else { return nil }
            pos = next + 4
        }
        for _ in 0..<answers {
            guard let next = skipName(d, pos), next + 10 <= d.count else { return nil }
            let type = Int(d[next]) << 8 | Int(d[next + 1])
            let length = Int(d[next + 8]) << 8 | Int(d[next + 9])
            let rdata = next + 10
            if type == 12 { return readName(d, rdata) }
            pos = rdata + length
        }
        return nil
    }

    private static func skipName(_ d: [UInt8], _ start: Int) -> Int? {
        var pos = start
        while pos < d.count {
            let len = Int(d[pos])
            if len == 0 { return pos + 1 }
            if len & 0xC0 == 0xC0 { return pos + 2 }
            pos += len + 1
        }
        return nil
    }

    private static func readName(_ d: [UInt8], _ start: Int) -> String? {
        var labels: [String] = []
        var pos = start
        var jumps = 0
        while pos < d.count, jumps < 16 {
            let len = Int(d[pos])
            if len == 0 { return labels.joined(separator: ".") }
            if len & 0xC0 == 0xC0 {
                guard pos + 1 < d.count else { return nil }
                pos = (len & 0x3F) << 8 | Int(d[pos + 1])
                jumps += 1
                continue
            }
            guard pos + 1 + len <= d.count else { return nil }
            labels.append(String(decoding: d[pos + 1..<pos + 1 + len], as: UTF8.self))
            pos += len + 1
        }
        return nil
    }
}
