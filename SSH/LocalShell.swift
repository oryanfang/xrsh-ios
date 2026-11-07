import Foundation
import UIKit

/// 本机命令行的命令解释器：App 沙盒里的一个小 shell。
/// 只做"一行命令进、一段文字出"，键盘输入和光标由 LocalSession 处理。
@MainActor
final class LocalShell {
    struct Result {
        var output = ""
        var clear = false
        var exit = false
    }

    struct Command {
        var argv: [String] = []
        var redirect: (path: String, append: Bool)?
    }

    /// 命令的 (标准输出, 错误输出)
    typealias Out = (out: String, err: String)

    // MARK: - 状态与外部回调

    let home: URL
    var cwd: URL
    private(set) var history: [String] = []
    var cols = 80

    var devices: () -> [SSHDevice] = { [] }
    var startScan: () -> Void = {}
    var openSSH: (_ host: String, _ port: Int, _ user: String?) -> Void = { _, _, _ in }

    static let commandNames = [
        "cat", "cd", "clear", "cp", "curl", "date", "devices", "df", "echo", "exit", "free", "grep",
        "head", "help", "history", "hostname", "ifconfig", "logout", "ls", "mkdir", "mv", "ping",
        "ps", "pwd", "rm", "scan", "ssh", "tail", "touch", "uname", "uptime", "wc", "whoami",
    ]

    enum Color {
        static let reset = "\u{1B}[0m"
        static let red = "\u{1B}[31m"
        static let green = "\u{1B}[32;1m"
        static let blue = "\u{1B}[34;1m"
        static let gray = "\u{1B}[90m"
    }

    init() {
        let documents = AppFolders.documents
        home = documents
        cwd = documents
    }

    // MARK: - 提示符

    /// 提示符（带颜色）和它在屏幕上占的列数
    func prompt() -> (text: String, width: Int) {
        let plain = "mobile@\(deviceName):\(displayPath)$ "
        let colored = "\(Color.green)mobile@\(deviceName)\(Color.reset):\(Color.blue)\(displayPath)\(Color.reset)$ "
        return (colored, Self.displayWidth(plain))
    }

    var deviceName: String {
        UIDevice.current.name.replacingOccurrences(of: " ", with: "-")
    }

    var displayPath: String {
        let path = cwd.path
        if path == home.path { return "~" }
        if path.hasPrefix(home.path + "/") { return "~" + path.dropFirst(home.path.count) }
        return path
    }

    // MARK: - 执行

    func remember(_ line: String) {
        if history.last != line { history.append(line) }
    }

    /// emit 用来边运行边输出（ping、curl 的进度）；最后一条命令且没有重定向时才会用到
    func execute(_ line: String, emit: @escaping (String) -> Void) async -> Result {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return Result() }
        remember(trimmed)

        guard let commands = parse(trimmed) else {
            return Result(output: Color.red + tr("语法错误：引号没有闭合") + Color.reset + "\n")
        }
        if commands.contains(where: { $0.argv.isEmpty }) {
            return Result(output: Color.red + tr("语法错误：命令不完整") + Color.reset + "\n")
        }

        var result = Result()
        var errors = ""
        var stdin: String?
        var finalOutput = ""

        for (index, command) in commands.enumerated() {
            let name = command.argv[0]
            if name == "clear" { result.clear = true }
            if name == "exit" || name == "logout" { result.exit = true }

            let isLast = index == commands.count - 1 && command.redirect == nil
            let (out, err) = await run(command.argv, stdin: stdin, emit: isLast ? emit : nil)
            errors += err

            if let redirect = command.redirect {
                if let problem = write(out, to: redirect.path, append: redirect.append) { errors += problem }
                stdin = ""
                finalOutput = ""
            } else {
                stdin = out
                finalOutput = out
            }
        }

        var output = errors
        output += finalOutput
        if !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
        result.output = output
        return result
    }

    func error(_ text: String) -> Out {
        ("", Color.red + text + Color.reset + "\n")
    }

    func write(_ text: String, to path: String, append: Bool) -> String? {
        let url = resolve(path)
        do {
            if append, let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
            } else {
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            return nil
        } catch {
            return Color.red + tr("无法写入 {0}", path) + Color.reset + "\n"
        }
    }

    // MARK: - 解析（引号、反斜杠、管道、重定向）

    func parse(_ line: String) -> [Command]? {
        var commands = [Command()]
        var word = ""
        var inWord = false
        var quote: Character?
        var pendingRedirect: Bool?   // 等待目标文件名，值是 "是否追加"
        let chars = Array(line)
        var i = 0

        func endWord() {
            guard inWord else { return }
            if let append = pendingRedirect {
                commands[commands.count - 1].redirect = (word, append)
                pendingRedirect = nil
            } else {
                commands[commands.count - 1].argv.append(word)
            }
            word = ""
            inWord = false
        }

        while i < chars.count {
            let c = chars[i]
            if let q = quote {
                if c == q {
                    quote = nil
                } else if c == "\\", q == "\"", i + 1 < chars.count {
                    i += 1
                    word.append(chars[i])
                } else {
                    word.append(c)
                }
            } else {
                switch c {
                case "'", "\"":
                    quote = c
                    inWord = true
                case "\\":
                    if i + 1 < chars.count {
                        i += 1
                        word.append(chars[i])
                        inWord = true
                    }
                case " ", "\t":
                    endWord()
                case "|":
                    endWord()
                    commands.append(Command())
                case ">":
                    endWord()
                    if i + 1 < chars.count, chars[i + 1] == ">" {
                        i += 1
                        pendingRedirect = true
                    } else {
                        pendingRedirect = false
                    }
                default:
                    word.append(c)
                    inWord = true
                }
            }
            i += 1
        }
        if quote != nil { return nil }
        endWord()
        if pendingRedirect != nil { return nil }
        return commands
    }

    // MARK: - 路径

    func resolve(_ path: String) -> URL {
        var p = path
        if p == "~" || p.hasPrefix("~/") { p = home.path + p.dropFirst() }
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : cwd.appendingPathComponent(p)
        return url.standardized
    }

    func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - 命令分发

    func run(_ argv: [String], stdin: String?, emit: ((String) -> Void)?) async -> Out {
        let args = Array(argv.dropFirst())
        switch argv[0] {
        case "help": return (helpText, "")
        case "clear", "exit", "logout": return ("", "")
        case "pwd": return (cwd.path + "\n", "")
        case "cd": return cd(args)
        case "ls": return ls(args)
        case "cat": return cat(args, stdin: stdin)
        case "echo": return echo(args)
        case "mkdir": return mkdir(args)
        case "rm": return rm(args)
        case "cp": return copyOrMove(args, move: false)
        case "mv": return copyOrMove(args, move: true)
        case "touch": return touch(args)
        case "head": return headTail(args, stdin: stdin, head: true)
        case "tail": return headTail(args, stdin: stdin, head: false)
        case "wc": return wc(args, stdin: stdin)
        case "grep": return grep(args, stdin: stdin)
        case "whoami": return ("mobile\n", "")
        case "hostname": return (UIDevice.current.name + "\n", "")
        case "uname": return uname(args)
        case "date": return (dateText, "")
        case "ifconfig": return (ifconfig(), "")
        case "devices": return (devicesText(), "")
        case "scan":
            startScan()
            return (tr("已开始扫描局域网，过几秒输入 devices 查看结果。\n"), "")
        case "ssh": return ssh(args)
        case "curl": return await curl(args, emit: emit)
        case "ping": return await ping(args, emit: emit)
        case "df": return df(args)
        case "uptime": return (uptimeText(), "")
        case "free": return free(args)
        case "ps": return ps()
        case "history":
            let text = history.enumerated().map { String(format: "%4d  %@", $0.offset + 1, $0.element) }
            return (text.joined(separator: "\n") + "\n", "")
        default:
            return error(tr("{0}: 命令未找到（输入 help 查看支持的命令）", argv[0]))
        }
    }

    var helpText: String {
        if AppLanguage.effective == .en {
            return """
            Local terminal: a small shell inside the app's sandbox (files stay in the app's own folder)

            Files     ls  cd  pwd  cat  mkdir  rm  cp  mv  touch  head  tail  wc  grep
            Info      echo  date  whoami  hostname  uname  ifconfig  history  clear
            System    df  free  uptime  ps (iOS only shows this app)
            Network   ping  curl  scan (scan the local network)  devices (list devices)  ssh [user@]host [-p port]
            Exit      exit

            Supports pipes |, redirects > >>, quotes, Tab completion, and ↑↓ for history.
            Examples: ls -l | grep txt      echo hi > a.txt      curl -O https://example.com/a.zip
            Press Ctrl+C to interrupt a running command (ping, curl downloads)

            """
        }
        return """
        本机终端：运行在 App 沙盒里的小命令行（文件都在 App 自己的文件夹里）

        文件    ls  cd  pwd  cat  mkdir  rm  cp  mv  touch  head  tail  wc  grep
        信息    echo  date  whoami  hostname  uname  ifconfig  history  clear
        系统    df  free  uptime  ps（iOS 只让看到本 App 自己）
        网络    ping  curl  scan（扫描局域网）  devices（列出设备）  ssh [用户@]主机 [-p 端口]
        退出    exit

        支持管道 |、重定向 > >>、引号，Tab 补全，↑↓ 翻历史。
        例：ls -l | grep txt      echo hi > a.txt      curl -O https://example.com/a.zip
        运行中按 Ctrl+C 可以中断（ping、curl 下载时用）

        """
    }

    // MARK: - Tab 补全

    /// 根据光标前的文字给出补全候选。word 是正在输入的那个词；
    /// 候选是替换这个词的完整文字（目录带 "/" 结尾）
    func complete(_ before: String) -> (word: String, candidates: [String]) {
        let word = String(before.split(separator: " ", omittingEmptySubsequences: false).last ?? "")
        let isFirstWord = !before.contains(" ")
        if isFirstWord, !word.contains("/") {
            return (word, Self.commandNames.filter { $0.hasPrefix(word) })
        }

        let slash = word.lastIndex(of: "/")
        let typedDir = slash.map { String(word[...$0]) } ?? ""
        let base = slash.map { String(word[word.index(after: $0)...]) } ?? word
        let dir = resolve(typedDir.isEmpty ? "." : typedDir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let candidates = names
            .filter { $0.hasPrefix(base) && (base.hasPrefix(".") || !$0.hasPrefix(".")) }
            .sorted()
            .map { typedDir + $0 + (isDirectory(dir.appendingPathComponent($0)) ? "/" : "") }
        return (word, candidates)
    }

    // MARK: - 显示宽度

    /// 字符串在终端里占的列数（中日韩和 emoji 占两列）
    static func displayWidth(_ text: String) -> Int {
        text.reduce(0) { $0 + displayWidth($1) }
    }

    static func displayWidth(_ character: Character) -> Int {
        guard let scalar = character.unicodeScalars.first else { return 0 }
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1F64F,
             0x1F900...0x1F9FF, 0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}
