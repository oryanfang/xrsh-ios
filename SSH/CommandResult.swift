import Foundation

/// 在设备上跑完一条命令的结果
nonisolated struct RemoteCommandResult: Sendable {
    var output: String
    /// 退出码；超时被放弃时为 nil
    var exitCode: Int?
    var timedOut = false
    /// 输出太长，中间省略了一部分
    var truncated = false
}

/// 只留输出的开头和结尾：开头有命令的概况，报错通常在最后，中间省略
nonisolated struct BoundedOutput: Sendable {
    private let headLimit: Int
    private let tailLimit: Int
    private var head: [UInt8] = []
    private var tail: [UInt8] = []
    private var omitted = 0

    init(limit: Int) {
        headLimit = limit / 2
        tailLimit = limit - limit / 2
    }

    mutating func append(_ chunk: ArraySlice<UInt8>) {
        let room = max(headLimit - head.count, 0)
        head.append(contentsOf: chunk.prefix(room))
        tail.append(contentsOf: chunk.dropFirst(room))
        if tail.count > tailLimit {
            omitted += tail.count - tailLimit
            tail.removeFirst(tail.count - tailLimit)
        }
    }

    var truncated: Bool { omitted > 0 }

    var text: String {
        let start = String(decoding: head, as: UTF8.self)
        let end = String(decoding: tail, as: UTF8.self)
        return truncated ? start + "\n... [\(omitted) bytes omitted] ...\n" + end : start + end
    }
}
