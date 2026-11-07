import Foundation

struct SSHDevice: Identifiable, Codable {
    var id: String { ipAddress }
    let ipAddress: String
    /// 22 端口是否开放；false 表示只是探测到设备在线
    var hasSSH = true
    var hostname: String?
    /// 用户手动设置的名称，优先于自动识别的主机名（单独按 IP 保存，不随设备列表保存）
    var alias: String?
    var banner: String?
    var openPorts: Set<UInt16> = []
    /// 通过 Bonjour 发现的服务类型，例如 "_airplay._tcp."
    var services: Set<String> = []
    var isGateway = false
    var firstSeen = Date()
    /// 最近一次确认在线的时间
    var lastSeen = Date()
    /// 在已有扫描记录的情况下新发现的设备
    var isNew = false
    /// 名字、端口、横幅最近一次探测的时间，近期探测过就不再重复探测
    var detailsAt: Date?
    /// 本轮扫描还没确认在线（显示的是上次保存的结果）
    var isOffline = false

    private enum CodingKeys: String, CodingKey {
        case ipAddress, hasSSH, hostname, banner, openPorts, services, isGateway
        case firstSeen, lastSeen, isNew, detailsAt
    }

    /// 界面上显示的名称
    var displayName: String? { alias ?? hostname }

    /// 根据端口、Bonjour 服务、SSH 横幅和名字推测设备类型，推测不出来就是 nil
    var deviceType: DeviceKind? {
        let name = (hostname ?? "").lowercased()
        let banner = (banner ?? "").lowercased()
        func hasService(_ prefixes: String...) -> Bool {
            services.contains { service in prefixes.contains { service.hasPrefix($0) } }
        }

        if openPorts.contains(62078) { return .iOS }
        if name.contains("macbook") || name.contains("imac") || name.contains("macmini") { return .mac }
        if name.contains("iphone") { return .iPhone }
        if name.contains("ipad") { return .iPad }
        if hasService("_airplay", "_companion-link", "_rdlink") { return .apple }
        if openPorts.contains(5555) { return .android }
        if banner.contains("windows") { return .windows }
        if banner.contains("raspbian") { return .raspberryPi }
        if banner.contains("ubuntu") { return .ubuntu }
        if banner.contains("debian") { return .debian }
        if banner.contains("freebsd") { return .freeBSD }
        if banner.contains("dropbear") { return .embedded }
        if isGateway, !openPorts.isDisjoint(with: [53, 80, 443]) { return .router }
        if !openPorts.isDisjoint(with: [8008, 8009]) { return .smartTV }
        if !openPorts.isDisjoint(with: [631, 9100]) { return .printer }
        if openPorts.contains(554) { return .camera }
        if !openPorts.isDisjoint(with: [139, 445]) { return .windowsOrNAS }
        if openPorts.contains(548) { return .macFileSharing }
        if hasService("_workstation") { return .linux }
        return nil
    }

    /// 用于按 IP 数值排序
    var sortKey: UInt32 {
        ipAddress.split(separator: ".").compactMap { UInt32($0) }.reduce(0) { $0 << 8 | $1 }
    }
}

/// 推测出来的设备类型。显示名跟着 App 语言走，图标也由它决定
enum DeviceKind {
    case iOS, mac, iPhone, iPad, apple, android, windows, raspberryPi, ubuntu, debian, freeBSD
    case embedded, router, smartTV, printer, camera, windowsOrNAS, macFileSharing, linux

    /// 中文名，同时也是翻译表里的键
    var chineseName: String {
        switch self {
        case .iOS: "iOS 设备"
        case .mac: "Mac"
        case .iPhone: "iPhone"
        case .iPad: "iPad"
        case .apple: "Apple 设备"
        case .android: "Android 设备"
        case .windows: "Windows"
        case .raspberryPi: "树莓派"
        case .ubuntu: "Linux (Ubuntu)"
        case .debian: "Linux (Debian)"
        case .freeBSD: "FreeBSD"
        case .embedded: "嵌入式 Linux / 路由器"
        case .router: "路由器"
        case .smartTV: "Chromecast / 智能电视"
        case .printer: "打印机"
        case .camera: "网络摄像头"
        case .windowsOrNAS: "Windows / NAS"
        case .macFileSharing: "NAS / Mac 文件共享"
        case .linux: "Linux"
        }
    }

    /// 按当前语言显示的名字
    var name: String { tr(chineseName) }

    /// 列表里的图标；没有专门图标的返回 nil
    var icon: String? {
        switch self {
        case .iOS, .iPhone: "iphone"
        case .iPad: "ipad"
        case .router: "wifi.router"
        case .printer: "printer"
        case .camera: "video"
        default: nil
        }
    }
}
