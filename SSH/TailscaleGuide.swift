import Darwin
import SwiftUI
import UIKit

/// 「从外面连回家」的说明。Tailscale 是单独的 App，xrsh 不需要接入它：
/// 它开着的时候，手机就能直接连到 100.x 地址或设备名，当普通地址填就行
struct TailscaleGuide: View {
    private static let linuxInstall = "curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up"

    @State private var address = Self.tailscaleAddress()

    var body: some View {
        List {
            Section {
                if let address {
                    Label(tr("Tailscale 已开启，这台手机的地址是 {0}", address), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.primary, .green)
                } else {
                    Label(tr("没有检测到 Tailscale"), systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text(tr("不在家也能连家里的设备。Tailscale 是另一个 App，xrsh 不需要它也能用，这个页面只是说明怎么配合。"))
            }

            Section(tr("1. 在手机上安装并登录")) {
                Link(tr("打开 Tailscale 下载页"), destination: URL(string: "https://tailscale.com/download/ios")!)
            }

            Section {
                Link(tr("其他系统的下载页"), destination: URL(string: "https://tailscale.com/download")!)
                VStack(alignment: .leading, spacing: 8) {
                    Text(tr("Linux 上运行："))
                    Text(Self.linuxInstall)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                    Button(tr("复制命令")) { UIPasteboard.general.string = Self.linuxInstall }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            } header: {
                Text(tr("2. 在要连的设备上安装"))
            } footer: {
                Text(tr("用同一个账号登录。设备本身还要开着 SSH。"))
            }

            Section {
                NavigationLink(tr("添加常用连接")) { SavedConnectionForm() }
            } header: {
                Text(tr("3. 把设备存进常用连接"))
            } footer: {
                Text(tr("在 Tailscale 的设备列表里找到它的 100.x 地址或设备名，填到主机那一栏。扫描只能找到同一个 Wi-Fi 里的设备，所以这些设备要手动添加。"))
            }
        }
        .navigationTitle(tr("从外面连回家"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { address = Self.tailscaleAddress() }
    }

    /// 找 VPN 网卡（utun）上 100.64.0.0/10 的地址。只看 utun：运营商的蜂窝网络也可能用这一段
    private static func tailscaleAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            defer { entry = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name).hasPrefix("utun"),
                  let raw = current.pointee.ifa_addr, raw.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let address = raw.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            let value = UInt32(bigEndian: address.s_addr)
            if value >> 22 == (100 << 2 | 1) { return String(cString: inet_ntoa(address)) }
        }
        return nil
    }
}
