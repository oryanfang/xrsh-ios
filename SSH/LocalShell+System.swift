import Foundation
import UIKit

/// 系统信息：uname、date、ifconfig、devices、ssh、df、uptime、free、ps
extension LocalShell {
    // MARK: - 系统信息

    func uname(_ args: [String]) -> Out {
        var info = utsname()
        Foundation.uname(&info)
        func field<T>(_ value: T) -> String {
            withUnsafeBytes(of: value) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
        }
        if args.contains("-a") {
            return ("\(field(info.sysname)) \(field(info.nodename)) \(field(info.release)) \(field(info.machine))\n", "")
        }
        return (field(info.sysname) + "\n", "")
    }

    var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateStyle = .full
        formatter.timeStyle = .medium
        return formatter.string(from: Date()) + "\n"
    }

    func ifconfig() -> String {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return tr("无法读取网络接口\n") }
        defer { freeifaddrs(list) }

        func text(_ address: UnsafeMutablePointer<sockaddr>) -> String {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            return String(cString: host)
        }

        var out = ""
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = pointer.pointee
            guard let address = item.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: item.ifa_name)
            let mask = item.ifa_netmask.map(text) ?? "-"
            out += tr("{0}{1}  掩码 {2}\n", name.padding(toLength: 8, withPad: " ", startingAt: 0), text(address), mask)
        }
        return out.isEmpty ? tr("没有可用的网络接口\n") : out
    }

    func devicesText() -> String {
        let list = devices().sorted { $0.sortKey < $1.sortKey }
        if list.isEmpty { return tr("还没有设备，先输入 scan 扫描局域网。\n") }
        return list.map { device in
            let ip = device.ipAddress.padding(toLength: 16, withPad: " ", startingAt: 0)
            let ssh = device.hasSSH ? Color.green + "SSH" + Color.reset : Color.gray + "-  " + Color.reset
            let name = device.displayName ?? "-"
            let type = device.deviceType.map { " · \($0.name)" } ?? ""
            let offline = device.isOffline ? Color.gray + tr("（离线）") + Color.reset : ""
            return "\(ip)\(ssh)  \(name)\(type)\(offline)"
        }.joined(separator: "\n") + "\n"
    }

    func ssh(_ args: [String]) -> Out {
        var port = 22
        var target: String?
        var index = 0
        while index < args.count {
            if args[index] == "-p", index + 1 < args.count, let p = Int(args[index + 1]) {
                port = p
                index += 1
            } else {
                target = args[index]
            }
            index += 1
        }
        guard let target, !target.isEmpty else { return error(tr("ssh: 用法：ssh [用户@]主机 [-p 端口]")) }
        let parts = target.split(separator: "@", maxSplits: 1).map(String.init)
        let (user, host) = parts.count == 2 ? (parts[0], parts[1]) : (nil, parts[0])
        openSSH(host, port, user)
        return (tr("已打开连接面板，请在面板里输入密码。\n"), "")
    }

    // MARK: - 系统信息命令（df、uptime、free、ps）

    func df(_ args: [String]) -> Out {
        let human = args.contains { $0.hasPrefix("-") && $0.contains("h") }
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        guard let values = try? home.resourceValues(forKeys: keys), let total = values.volumeTotalCapacity else {
            return error(tr("df: 读不到磁盘信息"))
        }
        let available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        let used = Int64(total) - available
        let percent = total > 0 ? Int((Double(used) / Double(total) * 100).rounded()) : 0

        func size(_ bytes: Int64) -> String {
            human ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "\(bytes / 1024)"
        }
        let head = human ? tr("文件系统        大小      已用      可用   已用%  挂载点") : tr("文件系统      1K-块        已用        可用   已用%  挂载点")
        let row = tr("本机存储   {0}   {1}   {2}   {3}%   /", size(Int64(total)), size(used), size(available), percent)
        return (head + "\n" + row + "\n", "")
    }

    func uptimeText() -> String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86400, hours = seconds % 86400 / 3600, minutes = seconds % 3600 / 60
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let up = days > 0 ? tr("{0} 天 {1}:{2}", days, hours, String(format: "%02d", minutes)) : "\(hours):\(String(format: "%02d", minutes))"
        return tr(" {0}  已运行 {1}，负载 {2}\n", time.string(from: Date()), up, String(format: "%.2f %.2f %.2f", load[0], load[1], load[2]))
    }

    func free(_ args: [String]) -> Out {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64()
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard status == KERN_SUCCESS else { return error(tr("free: 读不到内存信息")) }

        let page = UInt64(sysconf(_SC_PAGESIZE))
        let total = ProcessInfo.processInfo.physicalMemory
        let free = UInt64(stats.free_count) * page
        let available = free + UInt64(stats.inactive_count) * page
        let used = total > available ? total - available : 0
        let human = args.contains { $0.hasPrefix("-") && $0.contains("h") }

        func text(_ bytes: UInt64) -> String {
            human ? ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory) : "\(bytes / 1024)"
        }
        let head = tr("           总共        已用        空闲        可用")
        let row = tr("内存:   {0}   {1}   {2}   {3}", text(total), text(used), text(free), text(available))
        return (head + "\n" + row + "\n", "")
    }

    func ps() -> Out {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return error(tr("ps: 读不到进程信息")) }
        let memory = ByteCountFormatter.string(fromByteCount: Int64(info.resident_size), countStyle: .memory)
        let cpu = Double(info.user_time.seconds + info.system_time.seconds)
        let row = String(format: tr("mobile   %d   %@   %.0f 秒   SSH"), getpid(), memory, cpu)
        let note = Color.gray + tr("（iOS 不允许看其他程序，这里只能看到本 App 自己）") + Color.reset
        return (tr("用户    进程号   内存   CPU 时间   命令\n{0}\n{1}\n", row, note), "")
    }
}
