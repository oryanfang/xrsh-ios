import Foundation
import UIKit

/// 网络命令：ping、curl
extension LocalShell {
    // MARK: - 网络命令（ping、curl）

    func ping(_ args: [String], emit: ((String) -> Void)?) async -> Out {
        var count = 4
        var host: String?
        var index = 0
        while index < args.count {
            if args[index] == "-c", index + 1 < args.count, let n = Int(args[index + 1]), n > 0 {
                count = n
                index += 1
            } else if !args[index].hasPrefix("-") {
                host = args[index]
            }
            index += 1
        }
        guard let host else { return error(tr("ping: 用法：ping [-c 次数] 主机")) }

        let target: sockaddr_in? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: PingTool.resolve(host)) }
        }
        guard let target else { return error(tr("ping: 无法解析 {0}", host)) }
        let address = PingTool.text(of: target)

        var out = ""
        func say(_ text: String) {
            if let emit { emit(text) } else { out += text }
        }

        say("PING \(host) (\(address)): 56 data bytes\n")
        var times: [Double] = []
        var sent = 0
        for sequence in 0..<count {
            if Task.isCancelled { break }
            sent += 1
            let reply: PingTool.Reply? = await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: PingTool.ping(target, sequence: UInt16(sequence), timeout: 2))
                }
            }
            if let reply {
                times.append(reply.milliseconds)
                let ttl = reply.ttl.map { " ttl=\($0)" } ?? ""
                say(String(format: "%d bytes from %@: icmp_seq=%d%@ time=%.1f ms\n", reply.bytes, address, sequence, ttl, reply.milliseconds))
            } else {
                say(tr("请求超时 icmp_seq={0}\n", sequence))
            }
            if sequence < count - 1, !Task.isCancelled { try? await Task.sleep(nanoseconds: 1_000_000_000) }
        }

        let lost = sent == 0 ? 0 : Double(sent - times.count) / Double(sent) * 100
        say(tr("\n--- {0} ping 统计 ---\n", host))
        say(String(format: tr("发送 %d 个包，收到 %d 个，丢包 %.0f%%\n"), sent, times.count, lost))
        if let low = times.min(), let high = times.max() {
            let average = times.reduce(0, +) / Double(times.count)
            say(String(format: tr("往返时间 最小/平均/最大 = %.1f/%.1f/%.1f ms\n"), low, average, high))
        }
        return (out, "")
    }

    func curl(_ args: [String], emit: ((String) -> Void)?) async -> Out {
        var url: String?
        var output: String?
        var remoteName = false, silent = false, head = false, includeHeaders = false
        var method: String?
        var body: String?
        var headers: [(String, String)] = []

        var index = 0
        func next() -> String? {
            index += 1
            return index < args.count ? args[index] : nil
        }
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "-o", "--output": output = next()
            case "-O", "--remote-name": remoteName = true
            case "-s", "--silent": silent = true
            case "-I", "--head": head = true
            case "-i", "--include": includeHeaders = true
            case "-L", "--location": break
            case "-X", "--request": method = next()
            case "-d", "--data": body = next()
            case "-H", "--header":
                if let header = next(), let colon = header.firstIndex(of: ":") {
                    headers.append((String(header[..<colon]), header[header.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
                }
            default:
                if arg.hasPrefix("-"), arg.count > 1 { return error(tr("curl: 不支持的选项 {0}", arg)) }
                url = arg
            }
            index += 1
        }

        guard var address = url else { return error(tr("curl: 用法：curl [-O] [-o 文件] [-s] [-I] [-X 方法] [-d 数据] [-H 头] 网址")) }
        if !address.contains("://") { address = "http://" + address }
        guard let target = URL(string: address), target.host != nil else { return error(tr("curl: 网址不对：{0}", address)) }

        var request = URLRequest(url: target)
        request.timeoutInterval = 30
        request.httpMethod = head ? "HEAD" : (method ?? (body != nil ? "POST" : "GET"))
        request.httpBody = body.map { Data($0.utf8) }
        request.setValue("curl/8.7.1", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type") }
        headers.forEach { request.setValue($0.1, forHTTPHeaderField: $0.0) }

        do {
            if output != nil || remoteName {
                return try await curlDownload(request, output: output, remoteName: remoteName, silent: silent, emit: emit)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return error(tr("curl: 响应不对")) }

            var out = ""
            if head || includeHeaders {
                out += "HTTP \(http.statusCode)\n"
                for (key, value) in http.allHeaderFields.sorted(by: { "\($0.key)" < "\($1.key)" }) {
                    out += "\(key): \(value)\n"
                }
                if !head { out += "\n" }
            }
            if !head {
                guard let text = String(data: data, encoding: .utf8) else {
                    return error(tr("curl: 返回的是二进制内容，用 -o 文件名 保存到本地"))
                }
                out += text
            }
            return (out, "")
        } catch {
            return self.error("curl: " + curlMessage(error))
        }
    }

    func curlDownload(_ request: URLRequest, output: String?, remoteName: Bool, silent: Bool,
                              emit: ((String) -> Void)?) async throws -> Out {
        var name = output ?? ""
        if name.isEmpty {
            let last = request.url?.lastPathComponent ?? ""
            name = last.isEmpty || last == "/" ? "index.html" : last
        }
        var destination = resolve(name)
        if isDirectory(destination) { destination = destination.appendingPathComponent(request.url?.lastPathComponent ?? "index.html") }

        // 进度只在输出到屏幕、百分比变化时刷新，避免刷屏
        let lastPercent = LockedValue(-1)
        let show = !silent ? emit : nil
        let (temp, response) = try await Downloader.download(request) { received, total in
            guard let show else { return }
            let percent = total > 0 ? Int(Double(received) * 100 / Double(total)) : -1
            if total > 0, !lastPercent.replace(percent) { return }
            let text = total > 0
                ? "\r  \(percent)%  \(ByteCountFormatter.string(fromByteCount: received, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))   "
                : tr("\r  已下载 {0}   ", ByteCountFormatter.string(fromByteCount: received, countStyle: .file))
            DispatchQueue.main.async { show(text) }
        }
        defer { try? FileManager.default.removeItem(at: temp) }

        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            return error(tr("curl: 服务器返回 {0}，没有保存", http.statusCode))
        }
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: temp, to: destination)
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        let line = tr("已保存到 {0}（{1}）\n", name, ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        return (silent ? "" : "\n" + line, "")
    }

    func curlMessage(_ error: Error) -> String {
        switch (error as? URLError)?.code {
        case .cancelled: return tr("已取消")
        case .notConnectedToInternet: return tr("没有网络连接")
        case .cannotFindHost, .dnsLookupFailed: return tr("无法解析主机名")
        case .timedOut: return tr("连接超时")
        case .cannotConnectToHost: return tr("连不上对方")
        case .secureConnectionFailed, .serverCertificateUntrusted: return tr("HTTPS 证书有问题")
        case .appTransportSecurityRequiresSecureConnection: return tr("系统不允许不加密的 http 连接，请换成 https")
        default: return error.localizedDescription
        }
    }
}

/// 跨线程用的小盒子：只在数值变化时返回 true（用来限制进度刷新频率）
private nonisolated final class LockedValue: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int

    init(_ value: Int) { self.value = value }

    func replace(_ new: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard new != value else { return false }
        value = new
        return true
    }
}
