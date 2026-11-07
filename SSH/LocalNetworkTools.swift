import Foundation

/// ping：用不需要特权的 ICMP socket 发一个回显请求，等回复
nonisolated enum PingTool {
    struct Reply {
        let milliseconds: Double
        let ttl: Int?
        let bytes: Int
    }

    static func resolve(_ host: String) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let info = result else { return nil }
        defer { freeaddrinfo(result) }
        return info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    static func text(of address: sockaddr_in) -> String {
        var raw = address.sin_addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count))
        return String(cString: buffer)
    }

    /// 阻塞地发一次并等回复；超时或失败返回 nil
    static func ping(_ target: sockaddr_in, sequence: UInt16, timeout: Double) -> Reply? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var packet = [UInt8](repeating: 0, count: 64)
        packet[0] = 8   // echo request
        packet[6] = UInt8(sequence >> 8)
        packet[7] = UInt8(sequence & 0xFF)
        for index in 8..<packet.count { packet[index] = UInt8(index) }
        let sum = ICMPPinger.checksum(packet)
        packet[2] = UInt8(sum >> 8)
        packet[3] = UInt8(sum & 0xFF)

        var destination = target
        let start = Date()
        let sent = withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 1500)
        let deadline = start.addingTimeInterval(timeout)
        while true {
            let remaining = Int32(deadline.timeIntervalSinceNow * 1000)
            if remaining <= 0 { return nil }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&descriptor, 1, remaining) > 0 else { return nil }

            let count = recv(fd, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            // 回复可能带 IP 头，先跳过
            var offset = 0
            var ttl: Int?
            if buffer[0] >> 4 == 4 {
                offset = Int(buffer[0] & 0x0F) * 4
                ttl = Int(buffer[8])
            }
            guard count > offset + 7, buffer[offset] == 0 else { continue }   // 0 = echo reply
            let replySequence = UInt16(buffer[offset + 6]) << 8 | UInt16(buffer[offset + 7])
            guard replySequence == sequence else { continue }
            return Reply(milliseconds: Date().timeIntervalSince(start) * 1000, ttl: ttl, bytes: count - offset)
        }
    }
}

/// curl 的下载：边下边回报进度，任务被取消时中止
nonisolated final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloaded: URL?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private let progress: @Sendable (Int64, Int64) -> Void

    private init(progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.progress = progress
    }

    /// 下载到一个临时文件，返回文件位置和响应
    static func download(
        _ request: URLRequest,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> (URL, URLResponse) {
        let downloader = Downloader(progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.start(request, continuation)
            }
        } onCancel: {
            downloader.cancel()
        }
    }

    private func start(_ request: URLRequest, _ continuation: CheckedContinuation<(URL, URLResponse), Error>) {
        lock.lock()
        self.continuation = continuation
        let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: OperationQueue())
        let task = session.downloadTask(with: request)
        self.session = session
        self.task = task
        lock.unlock()
        task.resume()
    }

    private func cancel() {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // 这个文件在回调返回后就会被系统删掉，必须立刻挪走
        let moved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: moved)
        lock.lock()
        downloaded = moved
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuation
        self.continuation = nil
        let file = downloaded
        lock.unlock()
        session.finishTasksAndInvalidate()

        if let error {
            continuation?.resume(throwing: error)
        } else if let file, let response = task.response {
            continuation?.resume(returning: (file, response))
        } else {
            continuation?.resume(throwing: URLError(.unknown))
        }
    }
}
