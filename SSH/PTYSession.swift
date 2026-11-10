import Darwin
import Foundation

/// 真正的本机 shell：在手机上启动一个 zsh / bash，通过伪终端（PTY）和终端视图相连。
/// 只有越狱环境、并且 App 带着特殊权限（见 Jailbreak/SSH.entitlements）才启动得起来；
/// 启动不了的话调用方会退回到 App 自带的小命令行。
@MainActor
final class PTYSession: TerminalSession {
    struct Launch {
        let shell: String
        /// roothide / rootless 越狱的根目录；传统越狱没有这个
        let jbroot: String?
    }

    /// 最近一次"真 shell 不可用"的原因，给小命令行的开场白显示
    nonisolated(unsafe) static var lastFailure: String?

    private let launch: Launch
    private var master: Int32 = -1
    private var pid: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    override var title: String { tr("本机终端") }
    override var isLocal: Bool { true }
    override var isDeviceShell: Bool { true }

    /// 启动失败返回 nil，原因记在 lastFailure 里
    init?(cols: Int, rows: Int) {
        guard let launch = Self.detect() else {
            Self.lastFailure = tr("没有找到可用的 shell（没检测到越狱环境）")
            return nil
        }
        guard let spawned = Self.spawn(launch, cols: cols, rows: rows) else { return nil }
        self.launch = launch
        master = spawned.master
        pid = spawned.pid
        super.init()
        state = .connected
        startReading()
        watchExit()
    }

    // MARK: - 找 shell

    /// 在常见位置找 shell：roothide 的随机根目录、rootless 的 /var/jb、传统越狱的系统目录
    nonisolated static func detect() -> Launch? {
        var roots: [String?] = []
        if let found = findJBRoot() { roots.append(found) }
        roots.append("/var/jb")
        roots.append(nil)

        for root in roots {
            let prefix = root ?? ""
            for relative in ["/usr/bin/zsh", "/bin/zsh", "/usr/bin/bash", "/bin/bash", "/bin/sh"] {
                let path = prefix + relative
                if access(path, X_OK) == 0 { return Launch(shell: path, jbroot: root) }
            }
        }
        return nil
    }

    /// roothide 把越狱文件放在 /var/containers/Bundle/Application/.jbroot-随机串
    private nonisolated static func findJBRoot() -> String? {
        let base = "/var/containers/Bundle/Application"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: base) else { return nil }
        return names.first { $0.hasPrefix(".jbroot-") }.map { base + "/" + $0 }
    }

    // MARK: - 启动进程

    private nonisolated static func spawn(_ launch: Launch, cols: Int, rows: Int) -> (master: Int32, pid: pid_t)? {
        let master = posix_openpt(O_RDWR | O_NOCTTY)
        guard master >= 0 else {
            lastFailure = tr("创建伪终端失败（{0}）", String(cString: strerror(errno)))
            return nil
        }
        guard grantpt(master) == 0, unlockpt(master) == 0, let slaveName = ptsname(master) else {
            lastFailure = tr("伪终端初始化失败（{0}）", String(cString: strerror(errno)))
            Darwin.close(master)
            return nil
        }
        let slavePath = String(cString: slaveName)
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)

        let environment = makeEnvironment(for: launch)

        // 先尝试用 root 身份启动，不行再退回普通用户
        for asRoot in [true, false] {
            var pid: pid_t = 0
            let status = spawnOnce(launch.shell, slavePath: slavePath, master: master,
                                   environment: environment, asRoot: asRoot, pid: &pid)
            if status == 0 { return (master, pid) }
            if !asRoot {
                lastFailure = tr("启动 shell 失败：{0}。App 需要用 Jailbreak/package.sh 打包并签上特殊权限", String(cString: strerror(status)))
            }
        }
        Darwin.close(master)
        return nil
    }

    private nonisolated static func makeEnvironment(for launch: Launch) -> [String] {
        let jb = launch.jbroot ?? ""
        let paths = ["/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin"]
        let path = (launch.jbroot == nil ? [] : paths.map { jb + $0 }) + paths.map { $0 }
        var env = [
            "TERM=xterm-256color",
            "LANG=en_US.UTF-8",
            // iOS 上 en_US.UTF-8 不完整，只靠 LANG 时 zsh 会退回单字节，中文显示成 <00ad>
            "LC_CTYPE=UTF-8",
            "HOME=/var/mobile",
            "SHELL=\(launch.shell)",
            "PATH=\(path.joined(separator: ":"))",
            "TMPDIR=/var/tmp",
        ]
        if let root = launch.jbroot { env.append("JBROOT=\(root)") }
        return env
    }

    private nonisolated static func spawnOnce(_ shell: String, slavePath: String, master: Int32,
                                              environment: [String], asRoot: Bool, pid: inout pid_t) -> Int32 {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addclose(&actions, master)
        // 新会话里打开从设备，它就成了这个 shell 的控制终端
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        SpawnHelpers.changeDirectory(&actions, to: "/var/mobile")

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(0x0400))   // POSIX_SPAWN_SETSID
        if asRoot, !SpawnHelpers.applyRootPersona(&attributes) { return EPERM }

        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0) } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        return posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
    }

    // MARK: - agent 跑命令

    override var canRunCommands: Bool { state == .connected }

    /// 另开一个进程跑，身份和这个 shell 一样（能 root 就 root）
    override func runCommand(_ command: String, timeout: TimeInterval) async throws -> RemoteCommandResult {
        try await LocalCommand.run(
            command,
            shell: launch.shell,
            environment: Self.makeEnvironment(for: launch),
            directory: "/var/mobile",
            timeout: timeout
        )
    }

    // MARK: - 读写

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .global())
        let fd = master
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else {
                source.cancel()
                return
            }
            let bytes = Array(buffer[0..<count])
            DispatchQueue.main.async { self?.receive(bytes[...]) }
        }
        source.resume()
        readSource = source
    }

    private func watchExit() {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        let child = pid
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, WNOHANG)
            self?.readSource?.cancel()
            self?.state = .closed
        }
        source.resume()
        exitSource = source
    }

    override func send(_ bytes: ArraySlice<UInt8>) {
        guard master >= 0, state == .connected else { return }
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(master, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    override func resize(cols: Int, rows: Int) {
        guard master >= 0 else { return }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(master, TIOCSWINSZ, &size)
    }

    override func close() {
        readSource?.cancel()
        exitSource?.cancel()
        if pid > 0 { kill(pid, SIGHUP) }
        if master >= 0 {
            Darwin.close(master)
            master = -1
        }
        if state == .connected || state == .connecting { state = .closed }
    }
}
