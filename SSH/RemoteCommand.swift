import Citadel
import Foundation
import NIO

/// 走 SSH 的执行通道跑一条命令（不碰用户正在用的终端），把输出和退出码拿回来。
/// 注意：超时只是 App 不再等了，远端的命令可能还在跑（Citadel 没有开放关闭这条通道的接口）。
/// 另外命令被信号杀死时对方不报退出码，Citadel 会当成正常结束，这里拿到的是 0。
nonisolated enum RemoteCommand {
    private actor Collector {
        private(set) var output: BoundedOutput
        private(set) var timedOut = false

        init(limit: Int) { output = BoundedOutput(limit: limit) }

        func append(_ chunk: [UInt8]) { output.append(chunk[...]) }

        func markTimedOut() { timedOut = true }
    }

    static func run(
        _ command: String,
        on client: SSHClient,
        timeout: TimeInterval = 30,
        limit: Int = 4000
    ) async throws -> RemoteCommandResult {
        let collector = Collector(limit: limit)

        let reader = Task<Int?, Error> {
            let stream = try await client.executeCommandStream(command)
            do {
                // 超过上限也继续读完，这样才拿得到退出码和结尾
                for try await chunk in stream {
                    switch chunk {
                    case .stdout(let buffer), .stderr(let buffer):
                        await collector.append(Array(buffer.readableBytesView))
                    }
                }
            } catch let failed as SSHClient.CommandFailed {
                return failed.exitCode
            }
            return Task.isCancelled ? nil : 0
        }
        let timer = Task {
            try await Task.sleep(for: .seconds(timeout))
            await collector.markTimedOut()
            reader.cancel()
        }
        defer { timer.cancel() }

        var exitCode: Int?
        do {
            exitCode = try await withTaskCancellationHandler {
                try await reader.value
            } onCancel: {
                reader.cancel()
            }
        } catch {
            // 超时发生在通道还没建好的时候，也按超时报告
            guard await collector.timedOut else { throw error }
        }
        try Task.checkCancellation()

        let output = await collector.output
        return RemoteCommandResult(
            output: output.text,
            exitCode: exitCode,
            timedOut: await collector.timedOut,
            truncated: output.truncated
        )
    }
}
