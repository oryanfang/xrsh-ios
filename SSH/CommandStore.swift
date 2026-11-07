import SwiftUI

/// 命令合集里的一个命令：人话说明 + 几个常见用法；越狱手机上缺的可以用 apt 装
struct StoreCommand: Identifiable {
    struct Usage: Identifiable {
        let id = UUID()
        /// 这个用法是干什么的
        let title: String
        /// 填进终端的命令
        let command: String
    }

    let id = UUID()
    let name: String
    /// 人话说明
    let summary: String
    let usages: [Usage]
    /// apt 里的包名；系统自带或装不了的命令是 nil
    var package: String?
    /// 装好后的可执行文件名，默认就是命令名
    var binary: String?
    /// 本机小命令行（App 自带）里也有
    var inMiniShell = false
    /// 补充说明，例如"软件源里没有这个命令"
    var note: String?

    var executable: String { binary ?? name }
}

struct StoreGroup: Identifiable {
    let id = UUID()
    let title: String
    let items: [StoreCommand]
}

private func usage(_ title: String, _ command: String) -> StoreCommand.Usage {
    StoreCommand.Usage(title: title, command: command)
}

/// 命令合集的内容。有包名的，都在 roothide 的软件源里查过确实存在。
enum CommandStore {
    static let groups: [StoreGroup] = [
        StoreGroup(title: "文件和文件夹", items: [
            StoreCommand(name: "ls", summary: "列出文件夹里有什么", usages: [
                usage("看当前目录", "ls"), usage("看详情（大小、时间、权限）", "ls -l"), usage("连隐藏文件一起看", "ls -la"),
            ], inMiniShell: true),
            StoreCommand(name: "cd", summary: "进入另一个文件夹", usages: [
                usage("进入某个文件夹", "cd "), usage("回到上一级", "cd .."), usage("回到家目录", "cd ~"),
            ], inMiniShell: true),
            StoreCommand(name: "pwd", summary: "我现在在哪个文件夹", usages: [usage("显示当前位置", "pwd")], inMiniShell: true),
            StoreCommand(name: "mkdir", summary: "新建文件夹", usages: [
                usage("新建一个", "mkdir "), usage("连上级目录一起建", "mkdir -p "),
            ], inMiniShell: true),
            StoreCommand(name: "touch", summary: "新建一个空文件", usages: [usage("新建文件", "touch ")], inMiniShell: true),
            StoreCommand(name: "cp", summary: "复制文件或文件夹", usages: [
                usage("复制文件", "cp "), usage("复制整个文件夹", "cp -r "),
            ], package: "coreutils", inMiniShell: true),
            StoreCommand(name: "mv", summary: "移动文件，或者给文件改名", usages: [usage("移动或改名", "mv ")],
                         package: "coreutils", inMiniShell: true),
            StoreCommand(name: "rm", summary: "删除文件（不进回收站，删了就没了）", usages: [
                usage("删除文件", "rm "), usage("删除整个文件夹", "rm -r "),
            ], package: "coreutils", inMiniShell: true),
            StoreCommand(name: "find", summary: "按名字、大小等条件找文件", usages: [
                usage("按名字找", "find . -name \"*.txt\""), usage("找大于 100MB 的文件", "find . -size +100M"),
            ], package: "findutils"),
            StoreCommand(name: "du", summary: "看文件夹占了多少空间", usages: [
                usage("看当前目录总大小", "du -sh ."), usage("看每个子文件夹的大小", "du -sh *"),
            ], package: "coreutils"),
        ]),
        StoreGroup(title: "看和改文件", items: [
            StoreCommand(name: "cat", summary: "把文件内容显示出来", usages: [usage("显示文件", "cat ")],
                         package: "coreutils", inMiniShell: true),
            StoreCommand(name: "head", summary: "只看文件开头几行", usages: [usage("看前 10 行", "head "), usage("看前 20 行", "head -n 20 ")],
                         package: "coreutils", inMiniShell: true),
            StoreCommand(name: "tail", summary: "只看文件结尾几行", usages: [usage("看后 10 行", "tail "), usage("一直盯着新增内容", "tail -f ")],
                         package: "coreutils", inMiniShell: true),
            StoreCommand(name: "grep", summary: "在文本里搜关键词", usages: [
                usage("在文件里搜", "grep \"关键词\" "), usage("不分大小写搜", "grep -i \"关键词\" "),
            ], package: "grep", inMiniShell: true),
            StoreCommand(name: "wc", summary: "数一数有多少行、多少字", usages: [usage("统计文件", "wc ")],
                         package: "coreutils", inMiniShell: true),
            StoreCommand(name: "nano", summary: "简单好上手的文本编辑器", usages: [
                usage("编辑文件", "nano "),
            ], package: "nano", note: "保存按 Ctrl+O 回车，退出按 Ctrl+X"),
            StoreCommand(name: "vim", summary: "功能强大的文本编辑器，要学一下才会用", usages: [
                usage("编辑文件", "vim "),
            ], package: "vim", note: "退出：按 Esc，输入 :q! 回车（不保存）"),
            StoreCommand(name: "micro", summary: "像普通软件一样用的编辑器，支持鼠标", usages: [usage("编辑文件", "micro ")], package: "micro"),
            StoreCommand(name: "less", summary: "一页一页翻看很长的内容", usages: [usage("翻看文件", "less ")],
                         package: "less", note: "按 q 退出"),
            StoreCommand(name: "tree", summary: "用树状图显示文件夹结构", usages: [usage("看当前目录的结构", "tree"), usage("只看两层", "tree -L 2")], package: "tree"),
            StoreCommand(name: "file", summary: "看一个文件到底是什么类型", usages: [usage("识别文件类型", "file ")], package: "file"),
            StoreCommand(name: "jq", summary: "整理、查看 JSON 数据", usages: [
                usage("漂亮地显示 JSON 文件", "jq . "), usage("接在 curl 后面整理接口返回", "curl -s 网址 | jq ."),
            ], package: "jq"),
            StoreCommand(name: "rg", summary: "在很多文件里飞快地搜文字（ripgrep）", usages: [usage("在当前目录搜", "rg \"关键词\"")], package: "ripgrep"),
            StoreCommand(name: "sed", summary: "批量替换文本", usages: [usage("把文件里的 a 换成 b 并显示", "sed 's/a/b/g' ")], package: "sed"),
            StoreCommand(name: "awk", summary: "按列处理文本", usages: [usage("显示每行的第一列", "awk '{print $1}' ")], package: "gawk", binary: "gawk"),
        ]),
        StoreGroup(title: "下载和传输", items: [
            StoreCommand(name: "curl", summary: "下载网址内容、测试接口", usages: [
                usage("看网页内容", "curl "), usage("下载文件（保持原名）", "curl -LO "), usage("下载并指定文件名", "curl -L -o 文件名 "),
            ], package: "curl", inMiniShell: true),
            StoreCommand(name: "wget", summary: "下载文件，断了可以接着下", usages: [usage("下载文件", "wget "), usage("断点续传", "wget -c ")], package: "wget"),
            StoreCommand(name: "aria2c", summary: "多线程下载，速度更快", usages: [usage("下载文件", "aria2c -x 8 ")], package: "aria2"),
            StoreCommand(name: "rsync", summary: "只同步有变化的文件，适合备份", usages: [usage("同步文件夹", "rsync -av 来源/ 目标/")], package: "rsync"),
            StoreCommand(name: "scp", summary: "通过 SSH 在两台设备之间复制文件", usages: [
                usage("传到另一台设备", "scp 文件 用户@主机:路径"), usage("从另一台设备拿下来", "scp 用户@主机:路径 ."),
            ], package: "openssh"),
            StoreCommand(name: "git", summary: "下载和管理代码仓库", usages: [usage("下载一个仓库", "git clone "), usage("更新已下载的仓库", "git pull")], package: "git"),
        ]),
        StoreGroup(title: "网络检查", items: [
            StoreCommand(name: "ping", summary: "测试能不能连到某个地址", usages: [
                usage("测试 4 次", "ping -c 4 "), usage("测试能不能上网", "ping -c 4 8.8.8.8"),
            ], package: "inetutils", inMiniShell: true),
            StoreCommand(name: "ifconfig", summary: "看这台设备的网络地址", usages: [usage("显示所有网卡", "ifconfig")], package: "network-cmds", inMiniShell: true),
            StoreCommand(name: "traceroute", summary: "看数据一路经过了哪些节点", usages: [usage("追踪路线", "traceroute ")], package: "network-cmds"),
            StoreCommand(name: "netstat", summary: "看当前有哪些网络连接", usages: [usage("显示所有连接", "netstat -an")], package: "network-cmds"),
            StoreCommand(name: "nmap", summary: "扫描一台设备开了哪些端口", usages: [usage("扫描常用端口", "nmap "), usage("扫描整个局域网段", "nmap -sn 192.168.1.0/24")], package: "nmap"),
            StoreCommand(name: "nc", summary: "测试端口通不通，手动收发数据（netcat）", usages: [usage("测试端口", "nc -vz 主机 端口")], package: "netcat"),
            StoreCommand(name: "telnet", summary: "连到某个端口手动聊几句", usages: [usage("连接端口", "telnet 主机 端口")], package: "inetutils"),
            StoreCommand(name: "lsof", summary: "看哪个程序在用哪个端口、哪个文件", usages: [usage("看哪些端口在被监听", "lsof -i -P -n | grep LISTEN")], package: "lsof"),
            StoreCommand(name: "ssh", summary: "登录另一台设备", usages: [usage("登录", "ssh 用户@主机"), usage("指定端口", "ssh -p 端口 用户@主机")], package: "openssh", inMiniShell: true),
            StoreCommand(name: "nslookup", summary: "查域名对应的 IP 地址", usages: [
                usage("用 ping 代替，能看到解析出的 IP", "ping -c 1 "),
            ], note: "这个命令在常见的越狱软件源里没有现成的包，所以用 ping 代替"),
        ]),
        StoreGroup(title: "压缩和解压", items: [
            StoreCommand(name: "tar", summary: "打包和解包（.tar.gz 这类）", usages: [
                usage("解压 .tar.gz", "tar -xzf "), usage("把文件夹打成 .tar.gz", "tar -czf 压缩包名.tar.gz 文件夹"),
            ], package: "tar"),
            StoreCommand(name: "zip", summary: "压缩成 zip", usages: [usage("压缩文件夹", "zip -r 压缩包名.zip 文件夹")], package: "zip"),
            StoreCommand(name: "unzip", summary: "解压 zip", usages: [usage("解压", "unzip ")], package: "unzip"),
            StoreCommand(name: "7z", summary: "解压和压缩 7z、rar 等多种格式", usages: [usage("解压", "7z x ")], package: "p7zip", binary: "7z"),
        ]),
        StoreGroup(title: "系统和程序", items: [
            StoreCommand(name: "ps", summary: "列出正在运行的程序", usages: [usage("列出所有", "ps aux"), usage("按名字找", "ps aux | grep ")], inMiniShell: true),
            StoreCommand(name: "top", summary: "实时看哪些程序最占资源", usages: [usage("看一次就退出", "top -l 1 | head -20")]),
            StoreCommand(name: "htop", summary: "更好看、更好用的程序监控", usages: [usage("打开", "htop")], package: "htop", note: "按 q 退出"),
            StoreCommand(name: "kill", summary: "结束一个程序（按进程号）", usages: [usage("结束程序", "kill ")]),
            StoreCommand(name: "killall", summary: "按名字结束程序", usages: [usage("结束同名的所有程序", "killall ")], package: "shell-cmds"),
            StoreCommand(name: "df", summary: "看磁盘还剩多少空间", usages: [usage("看存储空间", "df -h")], inMiniShell: true),
            StoreCommand(name: "free", summary: "看内存用了多少", usages: [usage("看内存", "free -h")], inMiniShell: true,
                         note: "手机系统自带的命令里没有它，App 的本机小命令行里有"),
            StoreCommand(name: "uptime", summary: "开机多久了、系统忙不忙", usages: [usage("查看", "uptime")], inMiniShell: true),
            StoreCommand(name: "uname", summary: "看系统和内核版本", usages: [usage("看详细信息", "uname -a")], inMiniShell: true),
            StoreCommand(name: "whoami", summary: "我现在是以谁的身份在用", usages: [usage("查看", "whoami")], inMiniShell: true),
            StoreCommand(name: "date", summary: "看现在的日期和时间", usages: [usage("查看", "date")], inMiniShell: true),
            StoreCommand(name: "ncdu", summary: "看哪些文件夹最占空间，能直接进去删", usages: [usage("分析当前目录", "ncdu")], package: "ncdu", note: "按 q 退出"),
            StoreCommand(name: "tmux", summary: "一个终端里开多个窗口，断线了也不丢", usages: [usage("新开一个会话", "tmux new -s main"), usage("回到之前的会话", "tmux attach -t main")], package: "tmux"),
            StoreCommand(name: "neofetch", summary: "一屏显示系统和硬件信息", usages: [usage("显示", "neofetch")], package: "neofetch"),
            StoreCommand(name: "sudo", summary: "临时用管理员身份运行命令", usages: [usage("以管理员运行", "sudo ")], package: "sudo"),
        ]),
        StoreGroup(title: "写程序", items: [
            StoreCommand(name: "python3", summary: "Python 编程语言", usages: [usage("进入交互模式", "python3"), usage("运行脚本", "python3 ")], package: "python3"),
            StoreCommand(name: "perl", summary: "Perl 脚本语言", usages: [usage("运行脚本", "perl ")], package: "perl"),
            StoreCommand(name: "clang", summary: "C / C++ 编译器", usages: [usage("编译一个 C 文件", "clang 源文件.c -o 程序名")], package: "clang"),
            StoreCommand(name: "make", summary: "按规则自动编译项目", usages: [usage("编译当前项目", "make")], package: "make"),
            StoreCommand(name: "go", summary: "Go 编程语言", usages: [usage("运行", "go run ")], package: "golang"),
            StoreCommand(name: "sqlite3", summary: "查看和修改 SQLite 数据库", usages: [usage("打开数据库", "sqlite3 ")], package: "sqlite3"),
        ]),
        StoreGroup(title: "软件包和越狱", items: [
            StoreCommand(name: "apt", summary: "安装、更新、卸载软件包", usages: [
                usage("更新软件源列表", "apt update"), usage("搜索软件包", "apt search "), usage("安装", "apt update && apt install "), usage("卸载", "apt remove "),
            ]),
            StoreCommand(name: "dpkg", summary: "查看已经装了哪些软件包", usages: [usage("列出所有已装的包", "dpkg -l"), usage("看某个包装了哪些文件", "dpkg -L ")]),
            StoreCommand(name: "uicache", summary: "刷新桌面上的 App 图标", usages: [usage("刷新所有", "uicache -a")]),
            StoreCommand(name: "sbreload", summary: "重启桌面（不重启手机）", usages: [usage("重启桌面", "sbreload")]),
        ]),
        StoreGroup(title: "终端", items: [
            StoreCommand(name: "echo", summary: "把一段文字显示出来", usages: [usage("显示文字", "echo hello"), usage("写进文件", "echo 内容 > 文件名")], inMiniShell: true),
            StoreCommand(name: "history", summary: "看以前输入过的命令", usages: [usage("查看", "history")], inMiniShell: true),
            StoreCommand(name: "clear", summary: "清空屏幕", usages: [usage("清屏", "clear")], inMiniShell: true),
        ]),
    ]

    /// 越狱环境里可执行文件可能在的目录
    private static func binaryDirectories() -> [String] {
        let root = PTYSession.detect()?.jbroot
        let prefixes = [root, "/var/jb", nil]
        let dirs = ["/usr/bin", "/bin", "/usr/local/bin", "/usr/sbin", "/sbin"]
        return prefixes.flatMap { prefix in dirs.map { (prefix ?? "") + $0 } }
    }

    /// 已经装好的命令（按可执行文件名）
    static func installedExecutables() -> Set<String> {
        let wanted = Set(groups.flatMap(\.items).map(\.executable))
        let dirs = binaryDirectories()
        return wanted.filter { name in
            dirs.contains { FileManager.default.isExecutableFile(atPath: $0 + "/" + name) }
        }
    }
}
