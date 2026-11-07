import Combine
import Foundation
import Network

enum HostProbe {
    case ssh        // 22 端口开放
    case reachable  // 22 端口拒绝连接，说明主机在线
    case silent     // 没有任何回应
}

@MainActor
final class NetworkScanner: ObservableObject {
    @Published var devices: [SSHDevice] = []
    var sshDevices: [SSHDevice] { devices.filter(\.hasSSH).sorted { $0.sortKey < $1.sortKey } }
    var otherDevices: [SSHDevice] { devices.filter { !$0.hasSSH }.sorted { $0.sortKey < $1.sortKey } }
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var localIP: String?
    @Published var subnetMask: String?
    @Published var totalHosts: Int = 0
    @Published var scannedHosts: Int = 0
    /// 上一次完整扫描结束的时间
    @Published var lastScanDate: Date? = UserDefaults.standard.object(forKey: lastScanKey) as? Date

    private static let aliasesKey = "deviceAliases"
    private static let devicesKey = "savedDevices.v1"
    private static let lastScanKey = "lastScanDate"
    /// 超过这个时间没再见到的设备会从保存的列表里清掉
    private static let retention: TimeInterval = 7 * 24 * 3600
    /// 这段时间内探测过名字和端口的设备，再次扫描时不重复探测
    static let detailsTTL: TimeInterval = 3600
    /// 手动设置的名称，按 IP 保存
    private var aliases: [String: String] = UserDefaults.standard.dictionary(forKey: aliasesKey) as? [String: String] ?? [:]
    var detailsInFlight: Set<String> = []
    private var didAutoScan = false
    private var persistPending = false

    init() {
        #if DEBUG
        // 只在调试版里：用演示数据，给 README 截图用，不会进正式安装包
        if UserDefaults.standard.bool(forKey: "xrshDemo") {
            devices = Self.demoDevices()
            localIP = "192.168.1.20"
            subnetMask = "255.255.255.0"
            lastScanDate = Date()
            didAutoScan = true
            return
        }
        #endif
        devices = Self.loadDevices().map { saved in
            var device = saved
            device.alias = aliases[device.ipAddress]
            device.isOffline = true
            return device
        }
    }

    #if DEBUG
    private static func demoDevices() -> [SSHDevice] {
        func device(_ ip: String, _ name: String?, ssh: Bool, banner: String? = nil,
                    ports: Set<UInt16> = [], gateway: Bool = false, new: Bool = false) -> SSHDevice {
            var d = SSHDevice(ipAddress: ip)
            d.hasSSH = ssh
            d.hostname = name
            d.banner = banner
            d.openPorts = ports
            d.isGateway = gateway
            d.isNew = new
            return d
        }
        return [
            device("192.168.1.1", "router.local", ssh: false, ports: [53, 80, 443], gateway: true),
            device("192.168.1.10", "macmini.local", ssh: true, banner: "SSH-2.0-OpenSSH_9.6"),
            device("192.168.1.23", "raspberrypi.local", ssh: true, banner: "SSH-2.0-OpenSSH_9.2p1 Raspbian-2+deb12u2"),
            device("192.168.1.31", "ubuntu-server.local", ssh: true, banner: "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13"),
            device("192.168.1.42", "iphone.local", ssh: true, banner: "SSH-2.0-OpenSSH_9.8", ports: [62078], new: true),
            device("192.168.1.60", "printer.local", ssh: false, ports: [631, 9100]),
        ]
    }
    #endif

    private static func loadDevices() -> [SSHDevice] {
        guard let data = UserDefaults.standard.data(forKey: devicesKey),
              let saved = try? JSONDecoder().decode([SSHDevice].self, from: data) else { return [] }
        let cutoff = Date().addingTimeInterval(-retention)
        return saved.filter { $0.lastSeen > cutoff }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Self.devicesKey)
        }
    }

    /// 名字、端口等信息陆续返回，合并成一次写入
    func persistSoon() {
        guard !persistPending else { return }
        persistPending = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            persistPending = false
            persist()
        }
    }

    /// 打开 App 后自动扫描一次，已保存的结果会先显示出来
    func autoScanOnce() {
        guard !didAutoScan, SettingsKey.bool(SettingsKey.autoScan) else { return }
        didAutoScan = true
        startScan()
    }

    /// 每次开始或停止扫描都会递增，用来让已经被取消的旧扫描不再修改状态
    private var scanGeneration = 0
    /// 同时进行的 TCP 探测数量上限，iOS 默认只允许约 256 个文件描述符
    private nonisolated static let maxConcurrentProbes = 96

    func startScan() {
        guard !isScanning else { return }

        isScanning = true
        progress = 0
        scannedHosts = 0

        scanGeneration += 1
        let generation = scanGeneration

        guard let (ip, mask) = getWiFiAddress() else {
            isScanning = false
            return
        }

        localIP = ip
        subnetMask = mask
        // 保留上次的结果，本轮确认在线的再逐个点亮
        for index in devices.indices { devices[index].isOffline = true }

        let ipRange = calculateIPRange(ip: ip, mask: mask)
        // 网段的第一个地址通常是路由器
        gatewayIP = ipRange.first
        totalHosts = ipRange.count

        startBonjour()

        Task {
            // ping 扫描和 TCP 扫描同时进行，ping 能发现没开 SSH 的在线设备
            async let alive = pingSweep(ipRange)
            await scanAll(ipRange: ipRange, generation: generation)
            let aliveIPs = await alive
            guard isCurrent(generation) else { return }

            for ip in aliveIPs {
                addDevice(ip: ip, hasSSH: false)
                // 待机的设备回应 22 端口可能比较慢，对没确认 SSH 的设备用更长的超时复查一次
                if devices.first(where: { $0.ipAddress == ip })?.hasSSH == false {
                    Task {
                        let probe = await self.probeHost(ip: ip, timeout: 3.0)
                        guard self.scanGeneration == generation else { return }
                        switch probe {
                        case .ssh: self.addDevice(ip: ip, hasSSH: true)
                        case .reachable: self.addDevice(ip: ip, hasSSH: false, definitive: true)
                        case .silent: break
                        }
                    }
                }
            }
            isScanning = false
            progress = 1.0
            let finished = Date()
            lastScanDate = finished
            UserDefaults.standard.set(finished, forKey: Self.lastScanKey)
            // 给 Bonjour 和名字探测留一点时间返回结果，然后保存
            try? await Task.sleep(for: .seconds(4))
            if scanGeneration == generation, !isScanning {
                stopBonjour()
                persist()
            }
        }
    }

    /// 清除保存的扫描结果（设备的自定义名称另外保存，不受影响）
    func clearSavedResults() {
        stopScan()
        devices = []
        lastScanDate = nil
        UserDefaults.standard.removeObject(forKey: Self.devicesKey)
        UserDefaults.standard.removeObject(forKey: Self.lastScanKey)
    }

    /// 设置设备名称，空字符串表示清除
    func setAlias(_ name: String, for ip: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            aliases[ip] = nil
        } else {
            aliases[ip] = trimmed
        }
        UserDefaults.standard.set(aliases, forKey: Self.aliasesKey)

        if let index = devices.firstIndex(where: { $0.ipAddress == ip }) {
            devices[index].alias = aliases[ip]
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        isScanning && scanGeneration == generation
    }

    func stopScan() {
        scanGeneration += 1
        isScanning = false
        stopBonjour()
        persist()
    }

    // MARK: - Bonjour (mDNS) hostnames

    /// 浏览的 Bonjour 服务类型，数字越小名字越优先。
    /// iPhone 等设备不广播 SSH，但会通过 rdlink / companion-link 等服务带上设备名。
    private static let bonjourTypes: [(type: String, priority: Int)] = [
        ("_ssh._tcp", 0),
        ("_sftp-ssh._tcp", 0),
        ("_workstation._tcp", 1),
        ("_companion-link._tcp", 2),
        ("_rdlink._tcp", 2),
        ("_airplay._tcp", 3),
    ]

    private var browsers: [NWBrowser] = []
    var bonjourNames: [String: (name: String, priority: Int)] = [:]
    private var resolvingServices: Set<String> = []
    private var resolvers: [ServiceResolver] = []
    private var bonjourServices: [String: Set<String>] = [:]
    private var gatewayIP: String?

    private func startBonjour() {
        stopBonjour()
        bonjourNames = [:]
        bonjourServices = [:]
        resolvingServices = []

        for (type, priority) in Self.bonjourTypes {
            // iPhone 的 rdlink 等服务只出现在点对点(AWDL)接口上，需要打开这个选项才能浏览到
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                let scanner = self
                Task { @MainActor in scanner?.handleBrowse(results, priority: priority) }
            }
            browser.start(queue: .global())
            browsers.append(browser)
        }
    }

    private func stopBonjour() {
        browsers.forEach { $0.cancel() }
        browsers = []
        resolvers = []
    }

    private func handleBrowse(_ results: Set<NWBrowser.Result>, priority: Int) {
        for result in results {
            guard case let .service(name, type, domain, _) = result.endpoint,
                  resolvingServices.insert("\(type)|\(name)").inserted else { continue }

            // 一个服务可能有多个地址（Wi-Fi、链路本地等），全部取回再和扫描到的 IP 匹配
            let resolver = ServiceResolver(name: name, type: type, domain: domain)
            resolver.onResolved = { [weak self] ips in
                Task { @MainActor in
                    for ip in ips { self?.recordBonjour(ip: ip, name: name, priority: priority, type: type) }
                }
            }
            resolvers.append(resolver)
            resolver.start()
        }
    }

    private func recordBonjour(ip: String, name: String, priority: Int, type: String) {
        bonjourServices[ip, default: []].insert(type)
        if let index = devices.firstIndex(where: { $0.ipAddress == ip }) {
            devices[index].services.insert(type)
        }
        if let existing = bonjourNames[ip], existing.priority <= priority { return }
        bonjourNames[ip] = (name, priority)
        if let index = devices.firstIndex(where: { $0.ipAddress == ip }) {
            devices[index].hostname = name
        }
    }

    // MARK: - Get WiFi IP address via getifaddrs

    private nonisolated func getWiFiAddress() -> (ip: String, mask: String)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            guard addrFamily == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            // en0 is WiFi on iOS
            guard name == "en0" else { continue }

            var addr = interface.ifa_addr.pointee
            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                        &hostname, socklen_t(hostname.count),
                        nil, 0, NI_NUMERICHOST)
            let ip = String(cString: hostname)

            var maskAddr = interface.ifa_netmask.pointee
            var maskHostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(&maskAddr, socklen_t(interface.ifa_netmask.pointee.sa_len),
                        &maskHostname, socklen_t(maskHostname.count),
                        nil, 0, NI_NUMERICHOST)
            let mask = String(cString: maskHostname)

            return (ip, mask)
        }
        return nil
    }

    // MARK: - Calculate IP range from IP and subnet mask

    private nonisolated func calculateIPRange(ip: String, mask: String) -> [String] {
        let ipParts = ip.split(separator: ".").compactMap { UInt32($0) }
        let maskParts = mask.split(separator: ".").compactMap { UInt32($0) }

        guard ipParts.count == 4, maskParts.count == 4 else { return [] }

        let ipNum = (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3]
        var maskNum = (maskParts[0] << 24) | (maskParts[1] << 16) | (maskParts[2] << 8) | maskParts[3]

        // 网段比 /24 大时只扫本机所在的 /24，否则一次要探测几万个地址
        if maskNum < 0xFFFF_FF00 { maskNum = 0xFFFF_FF00 }

        let network = ipNum & maskNum
        let broadcast = network | ~maskNum

        func format(_ addr: UInt32) -> String {
            "\((addr >> 24) & 0xFF).\((addr >> 16) & 0xFF).\((addr >> 8) & 0xFF).\(addr & 0xFF)"
        }

        switch maskNum {
        case 0xFFFF_FFFF:  // /32：只有自己
            return []
        case 0xFFFF_FFFE:  // /31：点对点链路，没有网络/广播地址，只有对端
            return [network, broadcast].filter { $0 != ipNum }.map(format)
        default:
            return ((network + 1)..<broadcast).map(format)
        }
    }

    // MARK: - Scan all IPs concurrently

    private func scanAll(ipRange: [String], generation: Int) async {
        await withTaskGroup(of: (String, HostProbe).self) { group in
            var remaining = ipRange.makeIterator()

            // 先放满并发上限，之后每完成一个再补一个，避免一次建出成百上千个连接
            for _ in 0..<Self.maxConcurrentProbes {
                guard let ip = remaining.next() else { break }
                group.addTask { (ip, await self.probeHost(ip: ip)) }
            }

            for await (ip, probe) in group {
                guard isCurrent(generation) else {
                    group.cancelAll()
                    break
                }
                scannedHosts += 1
                progress = totalHosts > 0 ? Double(scannedHosts) / Double(totalHosts) : 1
                switch probe {
                case .ssh: addDevice(ip: ip, hasSSH: true)
                case .reachable: addDevice(ip: ip, hasSSH: false, definitive: true)
                case .silent: break
                }
                if let next = remaining.next() {
                    group.addTask { (next, await self.probeHost(ip: next)) }
                }
            }
        }
    }

    /// definitive 表示 22 端口明确拒绝了连接，可以确定这台设备现在没开 SSH
    private func addDevice(ip: String, hasSSH: Bool, definitive: Bool = false) {
        if let index = devices.firstIndex(where: { $0.ipAddress == ip }) {
            devices[index].isOffline = false
            devices[index].lastSeen = Date()
            if hasSSH && !devices[index].hasSSH {
                devices[index].hasSSH = true
            } else if !hasSSH && definitive && devices[index].hasSSH {
                devices[index].hasSSH = false
                devices[index].banner = nil
            }
            let device = devices[index]
            Task { await self.fillDetails(for: device) }
            return
        }
        if !hasSSH && ip == localIP { return }

        var device = SSHDevice(ipAddress: ip, hasSSH: hasSSH)
        device.isGateway = ip == gatewayIP
        device.alias = aliases[ip]
        device.services = bonjourServices[ip] ?? []
        // 第一次扫描时所有设备都是新的，这时不打"新"标记
        device.isNew = lastScanDate != nil
        devices.append(device)
        // 设备先显示出来，主机名解析完成后再补上
        Task { await self.fillDetails(for: device) }
    }
}
