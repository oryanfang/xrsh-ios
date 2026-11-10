import SwiftUI
import UIKit

/// 设置页：搜索（设备和设置项一起搜）+ 终端、扫描、安全、文件、关于
struct SettingsView: View {
    @ObservedObject var scanner: NetworkScanner

    @AppStorage(SettingsKey.terminalFontSize) private var fontSize = SettingsKey.defaultFontSize
    @AppStorage(SettingsKey.preferRealShell) private var preferRealShell = true
    @AppStorage(SettingsKey.autoScan) private var autoScan = true
    @AppStorage(SettingsKey.sshGuide) private var sshGuide = false
    @AppStorage(SettingsKey.autoReconnect) private var autoReconnect = false
    @AppStorage(SettingsKey.keyRevision) private var keyRevision = 0
    @AppStorage(SettingsKey.tmuxResume) private var tmuxResume = false
    @AppStorage(SettingsKey.deviceTools) private var deviceTools = false
    @AppStorage(SettingsKey.savedConnectionsEnabled) private var savedEnabled = false
    @AppStorage(SettingsKey.savedConnections) private var savedData = Data()
    @AppStorage(SettingsKey.agentEnabled) private var agentEnabled = false
    @AppStorage(SettingsKey.agentIncludeOutput) private var agentIncludeOutput = true
    @AppStorage(SettingsKey.agentKeepConversation) private var agentKeepConversation = false
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    @State private var query = ""
    @State private var confirming: Confirmation?
    @State private var knownHostCount = 0

    private enum Confirmation: Identifiable {
        case passwords, keys, hosts, scanResults
        var id: Self { self }
    }

    private var keyword: String { query.trimmingCharacters(in: .whitespaces).lowercased() }
    private var isSearching: Bool { !keyword.isEmpty }

    /// 搜索时，只显示关键词能对上的设置分组
    private func show(_ words: String) -> Bool {
        !isSearching || words.lowercased().contains(keyword) || tr(words).lowercased().contains(keyword)
    }

    private var matchingDevices: [SSHDevice] {
        scanner.devices.filter { device in
            [device.ipAddress, device.displayName, device.deviceType?.chineseName, device.deviceType?.name, device.banner]
                .compactMap { $0 }.joined(separator: " ").lowercased().contains(keyword)
        }
        .sorted { $0.sortKey < $1.sortKey }
    }

    private var anySettingMatches: Bool {
        [languageWords, terminalWords, savedWords, agentWords, scanWords, securityWords, filesWords, aboutWords].contains { show($0) }
    }

    private let terminalWords = "终端 字体 大小 字号 本机 真 shell 越狱 重连 断线 tmux 接回 terminal font size local jailbreak reconnect resume"
    private let savedWords = "常用 连接 保存 地址 外面 回家 公网 saved connections favorite tailscale remote vpn"
    private let agentWords = "AI 助手 模型 接口 密钥 agent assistant model api key xr"
    private let scanWords = "扫描 自动 设备 结果 缓存 清除 引导 怎么开 小工具 网页 唤醒 mac tools web wake on lan scan automatic device results cache clear guide how to enable ssh"
    private let securityWords = "安全 密码 钥匙串 主机 密钥 清除 记住 security password keychain host key remember"
    private let filesWords = "文件 下载 文件夹 传文件 位置 files download folder transfer location"
    private let languageWords = "语言 language english 中文 切换"
    private let aboutWords = "关于 版本 构建 编号 越狱 shell 开源 许可 about version build jailbreak open source license"

    var body: some View {
        NavigationStack {
            List {
                if isSearching {
                    let devices = matchingDevices
                    if !devices.isEmpty {
                        Section(tr("设备")) {
                            ForEach(devices) { DeviceRow(device: $0) }
                        }
                    }
                    if devices.isEmpty && !anySettingMatches {
                        Text(tr("没有找到「{0}」相关的设备或设置", query))
                            .foregroundStyle(.secondary)
                    }
                }

                if show(languageWords) { languageSection }
                if show(terminalWords) { terminalSection }
                if show(savedWords) { savedSection }
                if show(agentWords) { agentSection }
                if show(scanWords) { scanSection }
                if show(securityWords) {
                    keyDevicesSection
                    securitySection
                }
                if show(filesWords) { filesSection }
                if show(aboutWords) { aboutSection }
            }
            .navigationTitle(tr("设置"))
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: tr("搜索设备或设置"))
            .onAppear { knownHostCount = Self.knownHosts().count }
            .alert(item: $confirming) { item in
                Alert(
                    title: Text(title(for: item)),
                    message: Text(message(for: item)),
                    primaryButton: .destructive(Text(tr("清除"))) { perform(item) },
                    secondaryButton: .cancel(Text(tr("取消")))
                )
            }
        }
    }

    // MARK: - 分组

    private var languageSection: some View {
        Section {
            Picker(tr("语言"), selection: $language) {
                ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
        } header: {
            Text(tr("语言"))
        } footer: {
            Text(tr("切换后立即生效。"))
        }
    }

    private var terminalSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tr("字体大小"))
                    Spacer()
                    Text("\(Int(fontSize))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $fontSize, in: 9...24, step: 1)
                Text(tr("ls -la  Hello 你好"))
                    .font(.system(size: CGFloat(fontSize), design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)

            Toggle(tr("优先使用真 shell"), isOn: $preferRealShell)
            Toggle(tr("断线后自动重连"), isOn: $autoReconnect)
            Toggle(tr("SSH 连上后进入 tmux"), isOn: $tmuxResume)
        } header: {
            Text(tr("终端"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("真 shell 只有在越狱的手机上才有。关掉后，进入本机终端会一直用 App 自带的小命令行。开启断线自动重连后，App 切到后台被系统断开，回来时会自动重连一次。"))
                Text(tr("进入 tmux 后，断线重连能接回原来的内容，正在跑的命令也不会停。对方要装了 tmux，没装就和平时一样；改了开关，下次连接才生效。在 tmux 里的 vim 搜索 /xr 会打开 AI 助手。"))
            }
        }
    }

    /// 常用连接：开关和列表
    private var savedSection: some View {
        Section {
            Toggle(tr("在设备页显示常用连接"), isOn: $savedEnabled)
            if savedEnabled {
                ForEach(SavedConnection.list(from: savedData)) { connection in
                    NavigationLink {
                        SavedConnectionForm(connection: connection)
                    } label: {
                        Text(connection.title)
                    }
                    .swipeActions {
                        Button(tr("删除"), role: .destructive) {
                            let list = SavedConnection.list(from: savedData).filter { $0.id != connection.id }
                            savedData = SavedConnection.encode(list)
                        }
                    }
                }
                NavigationLink(tr("添加常用连接")) { SavedConnectionForm() }
                NavigationLink(tr("从外面连回家")) { TailscaleGuide() }
            }
        } header: {
            Text(tr("常用连接"))
        } footer: {
            Text(tr("手动填地址的设备（比如公网服务器）可以存在这里，点一下就连。这里只存地址和用户名，密码还是在钥匙串里。"))
        }
    }

    private var agentSection: some View {
        Section {
            Toggle(tr("打开 AI 助手"), isOn: $agentEnabled)
            if agentEnabled {
                NavigationLink(tr("连接 AI")) { AgentSetupForm() }
                Toggle(tr("默认带上最近的终端输出"), isOn: $agentIncludeOutput)
                Toggle(tr("保留 AI 对话"), isOn: $agentKeepConversation)
            }
        } header: {
            Text(tr("AI 助手"))
        } footer: {
            Text(tr("默认关闭，关着不会发任何请求。打开后，在终端输入 /xr 来用，也可以从右下角的小三角进入。只读的命令会自动运行，其他命令都要你确认。保留对话后，退出后再输入 /xr 可以接着聊，点「断开」或输入 /clear 才会清空；对话越长，每次发给 AI 的内容越多。"))
        }
    }

    private var scanSection: some View {
        Section {
            Toggle(tr("打开 App 时自动扫描"), isOn: $autoScan)
            Toggle(tr("显示「怎么开 SSH」引导"), isOn: $sshGuide)
            Toggle(tr("设备小工具"), isOn: $deviceTools)
            Button(tr("清除保存的扫描结果"), role: .destructive) { confirming = .scanResults }
        } header: {
            Text(tr("扫描"))
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text(tr("设备的自定义名称不会被清除。"))
                Text(tr("打开设备小工具后，长按设备可以打开它的网页、用网络唤醒叫醒它。能不能唤醒取决于对方设备是否开了这个功能。"))
            }
        }
    }

    /// 设置过免密登录的设备，可以逐个删除
    private var keyAccounts: [String] {
        _ = keyRevision
        return Keychain.keyAccounts().sorted()
    }

    private func keyTitle(_ account: String) -> String {
        guard let parsed = Keychain.parse(account) else { return account }
        let name = scanner.devices.first { $0.ipAddress == parsed.host }?.displayName
        return name.map { "\($0)（\(account)）" } ?? account
    }

    @ViewBuilder
    private var keyDevicesSection: some View {
        let accounts = keyAccounts
        if !accounts.isEmpty {
            Section {
                ForEach(accounts, id: \.self) { account in
                    Label(keyTitle(account), systemImage: "star.fill")
                        .foregroundStyle(.primary, .yellow)
                        .font(.callout)
                        .swipeActions {
                            Button(tr("删除"), role: .destructive) { Keychain.deletePrivateKey(account) }
                        }
                }
            } header: {
                Text(tr("免密登录的设备"))
            } footer: {
                Text(tr("向左滑可以删除某台设备的免密登录，对方设备上的公钥不会被删除。"))
            }
        }
    }

    private var securitySection: some View {
        Section {
            Button(tr("清除保存的密码"), role: .destructive) { confirming = .passwords }
            Button(tr("清除免密登录的密钥"), role: .destructive) { confirming = .keys }
            Button(tr("清除已记住的主机密钥（{0} 台）", knownHostCount), role: .destructive) { confirming = .hosts }
        } header: {
            Text(tr("安全"))
        } footer: {
            Text(tr("密码保存在系统钥匙串里。主机密钥用来发现有人冒充你连接的设备，清除后下次连接会重新记住。"))
        }
    }

    private var filesSection: some View {
        Section {
            LabeledContent(tr("下载文件夹")) {
                Text(AppFolders.downloads.path)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
                    .multilineTextAlignment(.trailing)
            }
            Button(tr("在「文件」App 中打开")) { openFilesApp() }
        } header: {
            Text(tr("文件"))
        } footer: {
            Text(tr("传文件下载的内容先放在这里；下载完会弹出「存储到…」面板，可以存进「文件」App 或发给别的 App。"))
        }
    }

    private var aboutSection: some View {
        Section(tr("关于")) {
            LabeledContent(tr("版本"), value: Self.versionText)
            LabeledContent(tr("构建编号"), value: Self.buildStamp ?? "—")
            NavigationLink(tr("开源许可")) { LicensesView() }
            LabeledContent(tr("真 shell")) {
                Text(Self.shellText)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .font(.footnote)
            }
        }
    }

    // MARK: - 清除操作

    private func title(for item: Confirmation) -> String {
        switch item {
        case .passwords: tr("清除保存的密码？")
        case .keys: tr("清除免密登录的密钥？")
        case .hosts: tr("清除已记住的主机密钥？")
        case .scanResults: tr("清除保存的扫描结果？")
        }
    }

    private func message(for item: Confirmation) -> String {
        switch item {
        case .passwords: tr("所有设备保存的密码都会删除，之后连接要重新输入。")
        case .keys: tr("手机上保存的密钥会删除，设备列表里的五角星也会消失，之后连接要用密码。对方设备上的公钥不会被删除。")
        case .hosts: tr("下次连接每台设备时会重新记住它的密钥，不会再核对是否被冒充过。")
        case .scanResults: tr("设备列表会清空，需要重新扫描。你给设备起的名字会保留。")
        }
    }

    private func perform(_ item: Confirmation) {
        switch item {
        case .passwords:
            Keychain.deleteAll()
        case .keys:
            Keychain.deleteAllPrivateKeys()
        case .hosts:
            UserDefaults.standard.removeObject(forKey: SettingsKey.knownHosts)
            knownHostCount = 0
        case .scanResults:
            scanner.clearSavedResults()
        }
    }

    // MARK: - 其他

    private func openFilesApp() {
        let downloads = AppFolders.downloads
        try? FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        if let url = URL(string: "shareddocuments://" + downloads.path) {
            UIApplication.shared.open(url)
        }
    }

    private static func knownHosts() -> [String: String] {
        SettingsKey.knownHostKeys
    }

    private static var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version)（\(build)）"
    }

    /// 打包时放进 App 的构建编号（Xcode 直接装的版本没有）
    private static var buildStamp: String? {
        guard let url = Bundle.main.url(forResource: "BuildStamp", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var shellText: String {
        if let launch = PTYSession.detect() { return launch.shell }
        return tr("未检测到，使用自带小命令行")
    }
}
