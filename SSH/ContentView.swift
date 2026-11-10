import SwiftUI
import UIKit

struct ContentView: View {
    @ObservedObject var scanner: NetworkScanner
    /// 点击 SSH 设备时调用，参数是设备 IP
    var onConnect: (String) -> Void = { _ in }
    /// 点常用连接时调用
    var onConnectSaved: (SavedConnection) -> Void = { _ in }
    /// 点"进入本机终端"时调用
    var onLocalTerminal: () -> Void = {}
    /// 免密登录的密钥有增减时会变，用来刷新五角星
    @AppStorage(SettingsKey.keyRevision) private var keyRevision = 0
    @AppStorage(SettingsKey.sshGuide) private var sshGuide = false
    @AppStorage(SettingsKey.deviceTools) private var deviceTools = false
    @AppStorage(SettingsKey.savedConnectionsEnabled) private var savedEnabled = false
    @AppStorage(SettingsKey.savedConnections) private var savedData = Data()
    @State private var showSaved = true
    @State private var macDevice: SSHDevice?
    @State private var draftMAC = ""
    @State private var wakeMessage: String?
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
                if deviceTools {
                    toolButtons(device)
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

    @ViewBuilder
    private func toolButtons(_ device: SSHDevice) -> some View {
        if let url = DeviceTools.webURL(for: device) {
            Button {
                UIApplication.shared.open(url)
            } label: {
                Label(tr("打开网页"), systemImage: "safari")
            }
        }
        if let mac = DeviceTools.savedMAC(for: device.ipAddress) {
            Button {
                wake(device, mac: mac)
            } label: {
                Label(tr("网络唤醒"), systemImage: "power")
            }
            Button {
                draftMAC = mac
                macDevice = device
            } label: {
                Label(tr("修改 MAC 地址"), systemImage: "pencil")
            }
        } else {
            Button {
                Task {
                    draftMAC = await DeviceTools.lookUpMAC(ip: device.ipAddress) ?? ""
                    macDevice = device
                }
            } label: {
                Label(tr("网络唤醒"), systemImage: "power")
            }
        }
    }

    private func wake(_ device: SSHDevice, mac: String) {
        let sent = DeviceTools.wake(mac: mac, ip: device.ipAddress, localIP: scanner.localIP, mask: scanner.subnetMask)
        wakeMessage = sent
            ? tr("唤醒信号已发出。设备要开着网络唤醒功能才会醒，这边收不到确认，等一会儿再扫描看看。")
            : tr("唤醒信号没有发出去，请确认手机连着同一个 Wi-Fi，并且允许 App 访问本地网络。")
    }

    private func saveMACAndWake() {
        guard let device = macDevice else { return }
        guard let mac = DeviceTools.normalizeMAC(draftMAC) else {
            wakeMessage = tr("MAC 地址格式不对，应该像 aa:bb:cc:dd:ee:ff。")
            return
        }
        DeviceTools.saveMAC(mac, for: device.ipAddress)
        wake(device, mac: mac)
    }

    /// 常用连接分组
    @ViewBuilder
    private var savedSection: some View {
        let list = SavedConnection.list(from: savedData)
        if savedEnabled, !list.isEmpty {
            Section {
                if showSaved {
                    ForEach(list) { connection in
                        HStack {
                            Image(systemName: "bookmark.fill")
                                .foregroundStyle(.blue)
                                .font(.title3)
                                .frame(width: 28)
                            VStack(alignment: .leading) {
                                Text(connection.title)
                                if !connection.name.isEmpty {
                                    Text(connection.address)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onConnectSaved(connection) }
                    }
                }
            } header: {
                SectionHeader(title: tr("常用连接"), count: list.count, isExpanded: $showSaved)
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

                savedSection
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
            .alert(tr("网络唤醒"), isPresented: Binding(
                get: { macDevice != nil },
                set: { if !$0 { macDevice = nil } }
            )) {
                TextField("aa:bb:cc:dd:ee:ff", text: $draftMAC)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(tr("保存并唤醒")) { saveMACAndWake() }
                Button(tr("取消"), role: .cancel) {}
            } message: {
                Text(tr("需要 {0} 的 MAC 地址，只保存在这台手机上。", macDevice?.ipAddress ?? ""))
            }
            .alert(tr("网络唤醒"), isPresented: Binding(
                get: { wakeMessage != nil },
                set: { if !$0 { wakeMessage = nil } }
            )) {
                Button(tr("好")) {}
            } message: {
                Text(wakeMessage ?? "")
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

#Preview {
    ContentView(scanner: NetworkScanner())
}
