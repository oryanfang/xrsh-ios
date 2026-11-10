import Foundation

/// 判断 AI 想跑的命令要不要用户确认。由这里的代码决定，不靠 AI 自觉（设备上的文字可能骗它）。
///
/// - 只读：只有能完全看懂、每一段都在白名单里，才自动跑；拿不准一律要确认。
/// - 禁止：尽力而为地拦下一批毁灭性命令。绕过去的写法（比如 base64 解码再执行）会落到「要确认」，仍然过不了用户这一关。
/// 这个文件不依赖 App 的其他部分，方便用 Tests/AgentSafety 单独测试。
nonisolated enum CommandSafety {
    enum Verdict: Equatable {
        case readOnly
        case needsConfirmation
        case forbidden
    }

    static func classify(_ command: String) -> Verdict {
        if isReadOnly(command) { return .readOnly }
        if isForbidden(command) { return .forbidden }
        return .needsConfirmation
    }

    // MARK: - 只读

    private struct Token {
        var text = ""
        /// 有没有引号外的通配符（shell 会把它展开成别的文件名）
        var hasGlob = false
    }

    private static let plainCommands: Set<String> = [
        "ls", "cat", "df", "du", "uname", "uptime", "whoami", "pwd", "id", "wc", "stat", "which", "echo",
        "free", "lsblk", "arch", "nproc", "sw_vers", "w", "who", "last", "lsof", "netstat", "vm_stat",
        "basename", "dirname", "realpath", "readlink", "column", "nl", "rev", "seq", "dpkg-query", "apt-cache",
    ]

    /// 会把文件内容读出来的命令：参数不能有通配符，否则可能读到不该读的
    private static let contentReaders: Set<String> = ["cat", "head", "tail", "grep", "sort"]

    /// 这些路径里的内容不自动发给 AI，要用户看一眼
    private static let sensitiveWords = [
        ".ssh", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".pem", ".key", ".p12", ".pfx", ".env", "shadow",
        "passw", "secret", "token", "credential", ".netrc", ".aws", ".gnupg", ".kube", "history", "keychain",
        "cookie", "wallet", ".npmrc", ".pypirc", "environ", "/dev/",
        // 手机上的私人数据：短信、通讯录、照片、各个 App 的数据
        "library/", "/containers/", "/media/", "sms.db",
    ]

    private static func isReadOnly(_ command: String) -> Bool {
        guard let segments = parse(command) else { return false }
        return segments.allSatisfy(isReadOnly(segment:))
    }

    private static func isReadOnly(segment: [Token]) -> Bool {
        guard let name = segment.first?.text else { return false }
        let tokens = Array(segment.dropFirst())
        let args = tokens.map(\.text)

        if args.contains(where: { arg in
            let lower = arg.lowercased()
            return sensitiveWords.contains { lower.contains($0) }
        }) { return false }
        if contentReaders.contains(name), tokens.contains(where: \.hasGlob) { return false }

        func flags(containing letters: String) -> Bool {
            args.contains { arg in
                arg.hasPrefix("-") && !arg.hasPrefix("--") && arg.contains { letters.contains($0) }
            }
        }

        switch name {
        case _ where plainCommands.contains(name):
            return true
        case "head":
            return true
        case "tail":
            // -f 会一直跟着不退出
            return !flags(containing: "fF") && !args.contains { $0.hasPrefix("--follow") || $0.hasPrefix("--retry") || $0.hasPrefix("--pid") }
        case "ps":
            // ps e / ps -E 会显示环境变量，里面可能有密码；ps -ef 里的 -e 只是「所有进程」
            return !args.contains { arg in
                let lower = arg.lowercased()
                if lower.contains("env") { return true }
                return arg.hasPrefix("-") ? arg.contains("E") : arg.contains("e")
            }
        case "date":
            // date -s、date 0101 会改系统时间
            return args.allSatisfy { $0.hasPrefix("+") || $0 == "-u" || $0 == "-R" || $0 == "--utc" || $0.hasPrefix("-I") }
        case "hostname":
            // hostname 新名字 会改主机名
            return args.allSatisfy { ["-f", "-s", "-i", "-I", "--fqdn", "--short"].contains($0) }
        case "file":
            // file -C 会写文件
            return !flags(containing: "C") && !args.contains { $0.hasPrefix("--compile") }
        case "sort":
            // sort -o 会写文件，--compress-program 会启动别的程序；长选项里带 o 的一律不放行
            return !flags(containing: "oTS") && !args.contains { $0.hasPrefix("--") && $0.contains("o") }
        case "grep":
            // 递归搜索会一下读很多文件
            return !flags(containing: "rRdD") && !args.contains {
                $0.hasPrefix("--") && ($0.contains("recursive") || $0.contains("director"))
            }
        case "cd":
            // 只换目录。下一段命令照样要过一遍判断，通配符可能绕开敏感目录的检查
            return !tokens.contains(where: \.hasGlob)
        case "find":
            // 只列文件名；这些选项会删文件、写文件或者启动别的程序
            let banned: Set<String> = ["-exec", "-execdir", "-ok", "-okdir", "-delete", "-fprint", "-fprint0", "-fprintf", "-fls"]
            return !args.contains { banned.contains($0) }
        case "tree":
            // tree -o 会写文件
            return !flags(containing: "o") && !args.contains { $0.hasPrefix("--") && $0.contains("output") }
        case "uniq":
            // uniq 输入 输出 的第二个文件会被写入，这里只放行管道里的用法
            return args.allSatisfy { $0.hasPrefix("-") }
        case "tr":
            // 只处理管道里的文字，不碰文件
            return true
        case "ss":
            // ss -K 会掐断连接
            return !flags(containing: "K") && !args.contains { $0.hasPrefix("--kill") }
        case "dmesg":
            // -c、-C 会清空内核日志
            return !flags(containing: "cCDEn") && !args.contains { $0.hasPrefix("--") && !$0.hasPrefix("--since") }
        case "sysctl":
            return !flags(containing: "w") && !args.contains { $0.contains("=") || $0.hasPrefix("--write") }
        case "ifconfig":
            // ifconfig en0 down 会关网卡，所以只放行查看的写法
            return args.count <= 1
        case "ip":
            guard let object = args.first, ["addr", "address", "a", "link", "l", "route", "r", "neigh", "n"].contains(object) else { return false }
            return args.count == 1 || (args.count == 2 && ["show", "list"].contains(args[1]))
        case "mount":
            return args.isEmpty
        case "git":
            // 只放行查看的子命令；--output 会写文件，--ext-diff 会启动别的程序
            guard let sub = args.first, ["status", "log", "diff", "show"].contains(sub) else {
                return args == ["branch"] || args == ["branch", "-a"] || args == ["branch", "-v"] || args == ["remote", "-v"]
            }
            return !args.contains { $0.hasPrefix("--output") || $0 == "--ext-diff" || $0 == "--textconv" || $0 == "-o" }
        case "docker":
            guard let sub = args.first else { return false }
            return ["ps", "images", "version", "info"].contains(sub)
        case "systemctl":
            guard let sub = args.first else { return false }
            return ["status", "list-units", "list-timers", "list-unit-files", "is-active", "is-enabled"].contains(sub)
        case "journalctl":
            // -f 不退出；这些长选项会清理或改动日志
            return !flags(containing: "fF") && !args.contains { arg in
                ["--follow", "--vacuum", "--rotate", "--flush", "--sync", "--relinquish", "--setup-keys"].contains { arg.hasPrefix($0) }
            }
        case "launchctl":
            return args.first == "list"
        case "diskutil":
            guard let sub = args.first else { return false }
            return ["list", "info"].contains(sub)
        case "dpkg":
            guard let sub = args.first else { return false }
            return ["-l", "-L", "-s", "--list", "--listfiles", "--status", "--get-selections", "--print-architecture"].contains(sub)
        case "apt":
            guard let sub = args.first else { return false }
            return ["list", "show", "policy", "search"].contains(sub)
        default:
            return false
        }
    }

    // MARK: - 安装命令：自动回答提示

    /// 用户点了「允许」之后，真正要跑的写法
    struct Prepared: Equatable {
        var command: String
        var timeout: TimeInterval
        /// 过程中的提问会被自动回答 y
        var answersPrompts: Bool
    }

    private static let packageCommand = try! NSRegularExpression(
        pattern: #"(^|[;&|]\s*)(sudo\s+)?(apt|apt-get)\s+(update|install|reinstall|remove|purge|upgrade|full-upgrade|dist-upgrade|autoremove)(\s|$)"#
    )

    static func answersPrompts(_ command: String) -> Bool {
        packageCommand.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) != nil
    }

    /// apt 没有终端时遇到提问会直接放弃，所以用 yes 替用户回答。
    /// 不用 -y：越狱软件源常常没有签名，带 -y 时 apt 会直接拒绝安装，回答提问才装得上。
    /// 装东西比较慢，等待时间放长。不是安装命令就原样返回
    static func prepare(_ command: String) -> Prepared {
        guard answersPrompts(command) else {
            return Prepared(command: command, timeout: 30, answersPrompts: false)
        }
        let wrapped = "export DEBIAN_FRONTEND=noninteractive; yes 2>/dev/null | (\n\(command)\n)"
        return Prepared(command: wrapped, timeout: 300, answersPrompts: true)
    }

    /// 按 ; && || | 切成几段。只要出现看不完全懂的写法（变量、命令替换、重定向、后台、转义……），就返回 nil
    private static func parse(_ command: String) -> [[Token]]? {
        var segments: [[Token]] = []
        var segment: [Token] = []
        var token: Token?
        let chars = Array(command)
        var index = 0
        var quote: Character?

        func endToken() {
            if let finished = token { segment.append(finished) }
            token = nil
        }
        func endSegment() -> Bool {
            endToken()
            guard !segment.isEmpty else { return false }
            segments.append(segment)
            segment = []
            return true
        }

        while index < chars.count {
            let c = chars[index]
            defer { index += 1 }
            if c.isNewline || (c.isASCII && c.asciiValue! < 0x20 && c != "\t") || c == "\u{7F}" { return nil }

            if let open = quote {
                if c == open {
                    quote = nil
                } else {
                    if open == "\"", c == "$" || c == "`" || c == "\\" || c == "!" { return nil }
                    token?.text.append(c)
                }
                continue
            }

            switch c {
            case " ", "\t":
                endToken()
            case "'", "\"":
                quote = c
                if token == nil { token = Token() }
            case ";":
                guard endSegment() else { return nil }
            case "|":
                if index + 1 < chars.count, chars[index + 1] == "|" { index += 1 }
                guard endSegment() else { return nil }
            case "&":
                guard index + 1 < chars.count, chars[index + 1] == "&" else { return nil }
                index += 1
                guard endSegment() else { return nil }
            case "\\", "$", "`", ">", "<", "(", ")", "{", "}", "#", "!":
                return nil
            case "*", "?", "[", "]":
                if token == nil { token = Token() }
                token?.text.append(c)
                token?.hasGlob = true
            default:
                if token == nil { token = Token() }
                token?.text.append(c)
            }
        }
        guard quote == nil, endSegment() else { return nil }
        return segments
    }

    // MARK: - 禁止

    private static let forbiddenPatterns: [NSRegularExpression] = [
        // 重启、关机（重启会丢越狱）、格式化
        #"(^|[^a-z0-9_.-])(reboot|shutdown|halt|poweroff|ldrestart|telinit|wipefs|newfs[a-z_]*|mkfs(\.[a-z0-9]+)?)($|[^a-z0-9_.-])"#,
        #"(^|[^a-z0-9_.-])init\s+[06]($|[^0-9])"#,
        // 直接写磁盘
        #"(^|[^a-z0-9_.-])dd\s[^;&|]*of=/dev/(?!null\b|stdout\b|stderr\b|zero\b)"#,
        #">\s*/dev/(r?disk|sd|hd|nvme|mmcblk|vd|xvd)"#,
        // 从根目录开始删
        #"(^|[^a-z0-9_.-])find\s+/(\s[^;&|]*)?\s-delete"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    /// 删了系统就废了的目录
    private static let protectedPaths: Set<String> = [
        "", "~", "$home", "${home}", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64", "/opt", "/private",
        "/proc", "/root", "/rootfs", "/sbin", "/sys", "/system", "/usr", "/users", "/var", "/var/jb", "/var/mobile",
        "/var/containers", "/var/containers/bundle", "/var/containers/bundle/application", "/applications", "/library",
    ]

    private static func isForbidden(_ command: String) -> Bool {
        // 去掉引号和转义，re""boot、r\eboot 这类写法也能认出来；iOS 和 macOS 的文件名不分大小写
        let text = command
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .lowercased()
        let range = NSRange(text.startIndex..., in: text)
        if forbiddenPatterns.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return true }
        // fork 炸弹
        if text.filter({ !$0.isWhitespace }).contains(":(){") { return true }

        // rm -r 指向根目录或系统目录
        for part in text.split(whereSeparator: { ";&|\n()".contains($0) }) {
            let words = part.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let rm = words.firstIndex(where: { $0 == "rm" || $0.hasSuffix("/rm") }) else { continue }
            let args = words[(rm + 1)...]
            let recursive = args.contains { $0 == "--recursive" || $0 == "--no-preserve-root" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("r")) }
            guard recursive else { continue }
            for arg in args where !arg.hasPrefix("-") {
                var path = arg
                while path.hasSuffix("/*") || path.hasSuffix("/.") { path.removeLast(2) }
                while path.hasSuffix("/") { path.removeLast() }
                // roothide 的越狱根目录是 .jbroot-随机串，删了越狱就没了
                if protectedPaths.contains(path) || path.contains(".jbroot") || path.contains("$jbroot") { return true }
            }
        }
        return false
    }
}

/// 发给 AI 之前，把看起来像密码、密钥的内容换掉。只是一层保险：规则之外的敏感内容它认不出来
nonisolated enum AgentRedactor {
    static let mark = "[REDACTED]"

    private static let rules: [(NSRegularExpression, String)] = [
        // 私钥（输出被截断时可能没有结尾）
        (#"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)"#, mark),
        // 地址里的密码 scheme://user:pass@host
        (#"(?i)([a-z][a-z0-9+.-]*://[^\s:/@]+:)[^\s/@]+(@)"#, "$1\(mark)$2"),
        // Authorization: Bearer xxx
        (#"(?i)(\b(?:bearer|basic)\s+)[A-Za-z0-9._~+/=-]{8,}"#, "$1\(mark)"),
        // password=xxx、API_TOKEN: xxx 这类键值
        (#"(?i)([a-z0-9_.-]*(?:password|passwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key|credential)[a-z0-9_.-]*["']?\s*[:=]\s*)("[^"\n]*"|'[^'\n]*'|[^\s,;]+)"#, "$1\(mark)"),
        // 常见服务的 Key 和 JWT
        (#"\b(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,})\b"#, mark),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// 返回替换后的文字和替换了几处
    static func redact(_ text: String) -> (text: String, count: Int) {
        var result = text
        var count = 0
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..., in: result)
            // 已经换掉的不重复计数
            let matches = regex.matches(in: result, range: range)
            count += matches.filter { match in
                Range(match.range, in: result).map { !result[$0].contains(mark) } ?? true
            }.count
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return (result, count)
    }
}
