import Foundation

/// 面板里的一条"人话版命令"
struct QuickCommand: Identifiable {
    let id = UUID()
    /// 人话描述，例如 "看当前目录里有什么"
    let title: String
    /// 实际填进终端的命令
    let command: String
    /// 危险操作的提醒文字；有值就会先弹确认框
    var warning: String?
    /// 本机命令行（App 自带的小 shell）里也能用
    var local = true
}

struct QuickCommandGroup: Identifiable {
    let id = UUID()
    let title: String
    let items: [QuickCommand]
}

enum CommandCatalog {
    static let groups: [QuickCommandGroup] = [
        QuickCommandGroup(title: "文件和文件夹", items: [
            QuickCommand(title: "看当前目录里有什么", command: "ls -la"),
            QuickCommand(title: "我现在在哪个目录", command: "pwd"),
            QuickCommand(title: "回到上一级目录", command: "cd .."),
            QuickCommand(title: "回到家目录", command: "cd ~"),
            QuickCommand(title: "新建文件夹", command: "mkdir "),
            QuickCommand(title: "看文本文件的内容", command: "cat "),
            QuickCommand(title: "复制文件", command: "cp "),
            QuickCommand(title: "移动或改名", command: "mv "),
            QuickCommand(title: "删除文件", command: "rm ",
                         warning: "这会删除文件，而且不能撤销。填入后还要你自己按回车才会执行。"),
            QuickCommand(title: "删除整个文件夹", command: "rm -r ",
                         warning: "这会连文件夹里的所有东西一起删掉，而且不能撤销。填入后还要你自己按回车才会执行。"),
        ]),
        QuickCommandGroup(title: "系统状态", items: [
            QuickCommand(title: "系统信息", command: "uname -a"),
            QuickCommand(title: "开机多久了、现在忙不忙", command: "uptime"),
            QuickCommand(title: "磁盘还剩多少空间", command: "df -h"),
            QuickCommand(title: "内存用了多少", command: "free -h"),
            QuickCommand(title: "现在登录的是谁", command: "whoami"),
            QuickCommand(title: "现在几点", command: "date"),
            QuickCommand(title: "重启这台设备", command: "sudo reboot", warning: "设备会立刻重启，你的连接也会断开。填入后还要你自己按回车才会执行。", local: false),
            QuickCommand(title: "关机", command: "sudo shutdown now", warning: "设备会关机，需要有人去按电源键才能再开。填入后还要你自己按回车才会执行。", local: false),
        ]),
        QuickCommandGroup(title: "网络", items: [
            QuickCommand(title: "看这台设备的 IP 地址", command: "ifconfig"),
            QuickCommand(title: "测试能不能上网", command: "ping -c 4 8.8.8.8"),
            QuickCommand(title: "看哪些端口在被使用", command: "lsof -i -P -n | grep LISTEN", local: false),
            QuickCommand(title: "下载一个网址的文件", command: "curl -O "),
        ]),
        QuickCommandGroup(title: "正在运行的程序", items: [
            QuickCommand(title: "实时查看程序占用（按 q 退出）", command: "top", local: false),
            QuickCommand(title: "列出所有程序", command: "ps aux"),
            QuickCommand(title: "按名字找程序", command: "ps aux | grep ", local: false),
            QuickCommand(title: "结束一个程序", command: "kill ", warning: "这会强行结束一个程序，没保存的内容会丢失。填入后还要你自己按回车才会执行。", local: false),
        ]),
        QuickCommandGroup(title: "终端", items: [
            QuickCommand(title: "清空屏幕", command: "clear"),
            QuickCommand(title: "看我以前输入过的命令", command: "history"),
        ]),
    ]


    // MARK: - 越狱手机本机（真 shell）

    /// 越狱手机上的真终端：命令按 iOS 越狱环境来写，不是 Linux 那一套
    static let deviceGroups: [QuickCommandGroup] = [
        QuickCommandGroup(title: "越狱常用操作", items: [
            QuickCommand(title: "重启桌面（注销，不重启手机）", command: "sbreload",
                         warning: "桌面会重启，正在用的 App 会被关掉。填入后还要你自己按回车才会执行。"),
            QuickCommand(title: "刷新所有 App 的图标", command: "uicache -a"),
            QuickCommand(title: "重启用户空间（比重启手机快）", command: "ldrestart",
                         warning: "手机会回到锁屏，所有 App 都会被关掉，有些越狱需要重新点一次启用。填入后还要你自己按回车才会执行。"),
            QuickCommand(title: "越狱根目录在哪", command: "echo $JBROOT"),
        ]),
        QuickCommandGroup(title: "软件包", items: [
            QuickCommand(title: "更新软件源列表", command: "apt update"),
            QuickCommand(title: "搜索软件包", command: "apt search "),
            QuickCommand(title: "安装软件包", command: "apt update && apt install "),
            QuickCommand(title: "看已经装了哪些包", command: "dpkg -l"),
            QuickCommand(title: "升级所有软件包", command: "apt upgrade -y",
                         warning: "会把所有已装的包升级，可能需要一段时间，个别包升级后要重启桌面。填入后还要你自己按回车才会执行。"),
            QuickCommand(title: "卸载软件包", command: "apt remove ",
                         warning: "会卸载这个软件包。卸载系统依赖的包可能让越狱出问题。填入后还要你自己按回车才会执行。"),
        ]),
        QuickCommandGroup(title: "文件和文件夹", items: groups[0].items),
        QuickCommandGroup(title: "手机状态", items: [
            QuickCommand(title: "系统信息", command: "uname -a"),
            QuickCommand(title: "开机多久了", command: "uptime"),
            QuickCommand(title: "存储还剩多少空间", command: "df -h"),
            QuickCommand(title: "现在登录的是谁", command: "whoami"),
            QuickCommand(title: "现在几点", command: "date"),
        ]),
        QuickCommandGroup(title: "网络", items: [
            QuickCommand(title: "看这台手机的 IP 地址", command: "ifconfig"),
            QuickCommand(title: "测试能不能上网", command: "ping -c 4 8.8.8.8"),
            QuickCommand(title: "看哪些端口在被使用", command: "lsof -i -P -n | grep LISTEN"),
            QuickCommand(title: "下载一个网址的文件", command: "curl -LO "),
        ]),
        QuickCommandGroup(title: "正在运行的程序", items: [
            QuickCommand(title: "看当前最占资源的程序", command: "top -l 1 | head -20"),
            QuickCommand(title: "列出所有程序", command: "ps aux"),
            QuickCommand(title: "按名字找程序", command: "ps aux | grep "),
            QuickCommand(title: "按名字结束一个程序", command: "killall ",
                         warning: "会强行结束同名的所有程序，没保存的内容会丢失。填入后还要你自己按回车才会执行。"),
        ]),
        QuickCommandGroup(title: "终端", items: [
            QuickCommand(title: "清空屏幕", command: "clear"),
            QuickCommand(title: "看我以前输入过的命令", command: "history"),
        ]),
    ]

    /// 这个会话该显示哪一套命令
    @MainActor
    static func groups(for session: TerminalSession) -> [QuickCommandGroup] {
        if session.limitedCommands { return groups(local: true) }
        if session.isDeviceShell { return deviceGroups }
        return groups
    }

    /// 本机命令行里只显示它能跑的命令
    static func groups(local: Bool) -> [QuickCommandGroup] {
        guard local else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter(\.local)
            return items.isEmpty ? nil : QuickCommandGroup(title: group.title, items: items)
        }
    }
}
