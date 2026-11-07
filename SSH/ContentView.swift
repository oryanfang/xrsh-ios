import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var scanner: NetworkScanner
    /// 点击 SSH 设备时调用，参数是设备 IP
    var onConnect: (String) -> Void = { _ in }
    /// 点"进入本机终端"时调用
    var onLocalTerminal: () -> Void = {}
    /// 免密登录的密钥有增减时会变，用来刷新五角星
    @AppStorage(SettingsKey.keyRevision) private var keyRevision = 0
    @AppStorage(SettingsKey.sshGuide) private var sshGuide = false
    @State private var guideDevice: SSHDevice?
    @State private var showSSH = true
    @State private var showOther = true
    @State private var renamingIP: String?
    @State private var draftName = ""

    private func row(_ device: SSHDevice) -> some View {
        DeviceRow(device: device, hasKey: keyHosts.contains(device.ipAddress))
            .contentShape(Rectangle())
            .onTapGesture {
                if device.hasSSH { onConnect(device.ipAddress) } else if sshGuide { guideDevice = device }
            }
            .contextMenu {
                if device.hasSSH {
                    Button {
                        onConnect(device.ipAddress)
                    } label: {
                        Label(tr("SSH 连接"), systemImage: "terminal")
                    }
                } else if sshGuide {
                    Button {
                        guideDevice = device
                    } label: {
                        Label(tr("怎么开 SSH"), systemImage: "questionmark.circle")
                    }
                }
                Button {
                    draftName = device.alias ?? ""
                    renamingIP = device.ipAddress
                } label: {
                    Label(tr("设置名称"), systemImage: "pencil")
                }
                if device.alias != nil {
                    Button(role: .destructive) {
                        scanner.setAlias("", for: device.ipAddress)
                    } label: {
                        Label(tr("清除名称"), systemImage: "xmark.circle")
                    }
                }
                Button {
                    UIPasteboard.general.string = device.ipAddress
                } label: {
                    Label(tr("复制 IP"), systemImage: "doc.on.doc")
                }
            }
    }

    /// 一个可以折叠的设备分组（SSH 设备 / 可探测到的设备）
    private func deviceSection(_ title: String, _ devices: [SSHDevice], isExpanded: Binding<Bool>,
                               empty: String) -> some View {
        Section {
            if isExpanded.wrappedValue {
                if devices.isEmpty {
                    Text(scanner.isScanning ? tr("正在扫描中...") : empty)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(devices) { row($0) }
                }
            }
        } header: {
            SectionHeader(title: title, count: devices.count, isExpanded: isExpanded)
        }
    }

    private var keyHosts: Set<String> {
        _ = keyRevision
        #if DEBUG
        // 演示数据（README 截图用）里让一台设备显示黄色星标；不签名的模拟器版用不了钥匙串
        if UserDefaults.standard.bool(forKey: "xrshDemo") { return ["192.168.1.10"] }
        #endif
        return Keychain.keyHosts()
    }

    var body: some View {
        NavigationStack {
            List {
                Section(tr("网络信息")) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(tr("本机 IP"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(scanner.localIP ?? tr("未连接 Wi-Fi"))
                            .font(.title2.monospaced().weight(.semibold))
                        HStack(spacing: 6) {
                            if let mask = scanner.subnetMask {
                                Text(tr("掩码 {0}", mask))
                                Text("·")
                            }
                            if scanner.isScanning {
                                Text(tr("正在刷新…"))
                            } else if let date = scanner.lastScanDate {
                                Text(tr("扫描于"))
                                RelativeTime(date: date)
                            } else {
                                Text(tr("从未扫描"))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)

                    Button {
                        onLocalTerminal()
                    } label: {
                        Label(tr("进入本机终端"), systemImage: "terminal")
                    }
                }

                if scanner.isScanning {
                    Section(tr("扫描进度")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: scanner.progress)
                            Text(tr("已扫描 {0}/{1}", scanner.scannedHosts, scanner.totalHosts))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                deviceSection(tr("SSH 设备"), scanner.sshDevices, isExpanded: $showSSH,
                              empty: tr("暂无发现 SSH 设备"))
                deviceSection(tr("可探测到的设备"), scanner.otherDevices, isExpanded: $showOther,
                              empty: tr("暂无其他可探测到的设备"))
            }
            .navigationTitle("xrsh")
            .refreshable {
                scanner.startScan()
                while scanner.isScanning { try? await Task.sleep(nanoseconds: 200_000_000) }
            }
            .task { scanner.autoScanOnce() }
            .sheet(item: $guideDevice) { SSHGuideSheet(device: $0) }
            .alert(tr("设置名称"), isPresented: Binding(
                get: { renamingIP != nil },
                set: { if !$0 { renamingIP = nil } }
            )) {
                TextField(tr("例如：Xperia 5 II"), text: $draftName)
                Button(tr("保存")) {
                    if let ip = renamingIP { scanner.setAlias(draftName, for: ip) }
                }
                Button(tr("取消"), role: .cancel) {}
            } message: {
                Text(renamingIP ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if scanner.isScanning {
                        Button {
                            scanner.stopScan()
                        } label: {
                            Label(tr("停止"), systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            scanner.startScan()
                        } label: {
                            Label(tr("扫描"), systemImage: "antenna.radiowaves.left.and.right")
                        }
                    }
                }
            }
        }
    }
}

private struct SectionHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack {
                Text(title)
                Spacer()
                if count > 0 {
                    Text(tr("{0} 台", count))
                        .font(.caption)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

struct DeviceRow: View {
    let device: SSHDevice
    /// 这台设备设置过免密登录，点一下就能直接进入，显示黄色五角星
    var hasKey = false

    private var icon: String {
        device.deviceType?.icon ?? (device.hasSSH ? "desktopcomputer" : "wifi")
    }

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundStyle(device.hasSSH ? .blue : .gray)
                .font(.title3)
                .frame(width: 28)
            VStack(alignment: .leading) {
                Text(device.ipAddress)
                    .font(.body.monospaced())
                let detail = [device.displayName, device.deviceType?.name].compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let banner = device.banner {
                    Text(tr("未获取到名称 · {0}", banner))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if device.isOffline {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(tr("上次在线 {0}", RelativeTime.text(device.lastSeen, now: context.date)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer()
            if device.isNew, Date().timeIntervalSince(device.firstSeen) < 24 * 3600 {
                Text(tr("新"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
            }
            if device.hasSSH {
                if hasKey {
                    Image(systemName: "star.fill")
                        .foregroundStyle(.yellow)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .opacity(device.isOffline ? 0.5 : 1)
    }
}

/// "3分钟前" 这样的相对时间，会自己每隔一会儿刷新
private struct RelativeTime: View {
    let date: Date
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    static func text(_ date: Date, now: Date) -> String {
        formatter.locale = AppLanguage.locale
        return now.timeIntervalSince(date) < 10 ? tr("刚刚") : formatter.localizedString(for: date, relativeTo: now)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Text(Self.text(date, now: context.date))
        }
    }
}

#Preview {
    ContentView(scanner: NetworkScanner())
}
