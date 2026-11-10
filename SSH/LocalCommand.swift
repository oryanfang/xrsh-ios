import Darwin
import Foundation

/// 在手机本机另开一个进程跑一条命令（shell -c），不碰用户正在用的那个 shell。
/// 没有终端、没有标准输入。超时或取消时会杀掉整组进程
nonisolated enum LocalCommand {
    static func run(
        _ command: String,
        shell: String,
        environment: [String],
        directory: String,
        timeout: TimeInterval = 30,
        limit: Int = 4000
    ) async throws -> RemoteCommandResult {
        let work = Task.detached {
            try runBlocking(command, shell: shell, environment: environment, directory: directory, timeout: timeout, limit: limit)
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func runBlocking(
        _ command: String,
        shell: String,
        environment: [String],
        directory: String,
        timeout: TimeInterval,
        limit: Int
    ) throws -> RemoteCommandResult {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw failure(errno) }
        let readEnd = fds[0], writeEnd = fds[1]
        defer { close(readEnd) }
        _ = fcntl(readEnd, F_SETFL, O_NONBLOCK)

        // 和真 shell 一样，先试 root，不行再用普通用户
        var pid: pid_t = 0
        var status: Int32 = EPERM
        for asRoot in [true, false] {
            status = spawn(command, shell: shell, environment: environment, directory: directory,
                           writeEnd: writeEnd, asRoot: asRoot, pid: &pid)
            if status == 0 { break }
        }
        close(writeEnd)
        guard status == 0 else { throw failure(status) }

        var output = BoundedOutput(limit: limit)
        var eof = false
        func drain() {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(readEnd, &buffer, buffer.count)
                if count > 0 {
                    output.append(buffer[0..<count])
                } else {
                    if count == 0 { eof = true }
                    return
                }
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        var waitStatus: Int32 = 0
        var timedOut = false
        var cancelled = false
        while true {
            if eof {
                usleep(50_000)
            } else {
                var request = pollfd(fd: readEnd, events: Int16(POLLIN), revents: 0)
                _ = poll(&request, 1, 100)
            }
            drain()
            // 只看 shell 本身有没有退出：它留在后台的子进程可能一直占着管道
            if waitpid(pid, &waitStatus, WNOHANG) == pid {
                drain()
                break
            }
            cancelled = Task.isCancelled
            timedOut = !cancelled && Date() >= deadline
            if cancelled || timedOut {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
                waitpid(pid, &waitStatus, 0)
                drain()
                break
            }
        }
        if cancelled { throw CancellationError() }

        // WIFEXITED / WEXITSTATUS 这些宏 Swift 用不了，手动算；被信号杀死按 shell 的惯例算成 128+信号
        let signal = waitStatus & 0x7F
        let exitCode = signal == 0 ? Int((waitStatus >> 8) & 0xFF) : 128 + Int(signal)
        return RemoteCommandResult(
            output: output.text,
            exitCode: timedOut ? nil : exitCode,
            timedOut: timedOut,
            truncated: output.truncated
        )
    }

    private static func spawn(
        _ command: String,
        shell: String,
        environment: [String],
        directory: String,
        writeEnd: Int32,
        asRoot: Bool,
        pid: inout pid_t
    ) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 1)
        posix_spawn_file_actions_adddup2(&actions, writeEnd, 2)
        SpawnHelpers.changeDirectory(&actions, to: directory)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // 自成一组，方便一起杀掉；其他打开的文件（比如真 shell 的伪终端）不传给它
        let setSID: Int32 = 0x0400, closeOthers: Int32 = 0x4000
        posix_spawnattr_setflags(&attributes, Int16(setSID | closeOthers))
        if asRoot, !SpawnHelpers.applyRootPersona(&attributes) { return EPERM }

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-c"), strdup(command), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        return posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
    }

    private static func failure(_ code: Int32) -> Error {
        NSError(domain: "SSH", code: Int(code), userInfo: [
            NSLocalizedDescriptionKey: tr("启动命令失败：{0}", String(cString: strerror(code))),
        ])
    }
}
