import SwiftUI
import UIKit

/// "这台设备没开 SSH，怎么开"：按设备类型给出步骤和可复制的命令
struct SSHGuide {
    var title: String
    var steps: [String]
    /// 可以一键复制的命令（命令本身不翻译）
    var commands: [String] = []
    /// 补充说明
    var note: String?

    static func make(for kind: DeviceKind?) -> SSHGuide {
        switch kind {
        case .mac:
            return SSHGuide(
                title: tr("在 Mac 上开启 SSH"),
                steps: [
                    tr("打开「系统设置」→「通用」→「共享」。"),
                    tr("打开「远程登录」开关。"),
                    tr("在「允许访问」里选择你的账户（或「所有用户」）。"),
                ],
                commands: ["sudo systemsetup -setremotelogin on"],
                note: tr("也可以在 Mac 的终端里直接运行下面这条命令。")
            )
        case .windows:
            return SSHGuide(
                title: tr("在 Windows 上开启 SSH"),
                steps: [
                    tr("以管理员身份打开 PowerShell。"),
                    tr("依次运行下面的命令：安装 OpenSSH 服务器、启动、设为开机自动启动。"),
                ],
                commands: [
                    "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0",
                    "Start-Service sshd",
                    "Set-Service -Name sshd -StartupType Automatic",
                ]
            )
        case .raspberryPi:
            return SSHGuide(
                title: tr("在树莓派上开启 SSH"),
                steps: [
                    tr("在树莓派的终端里运行下面的命令。"),
                    tr("或者运行 sudo raspi-config，进入 Interface Options → SSH 打开。"),
                ],
                commands: ["sudo systemctl enable --now ssh"]
            )
        case .ubuntu, .debian, .linux:
            return SSHGuide(
                title: tr("在 Linux 上开启 SSH"),
                steps: [
                    tr("在这台设备的终端里安装 SSH 服务。"),
                    tr("启动它，并设为开机自动启动。"),
                ],
                commands: [
                    "sudo apt update && sudo apt install openssh-server",
                    "sudo systemctl enable --now ssh",
                ],
                note: tr("不是 Debian / Ubuntu 系的系统，安装命令换成对应的包管理器，服务名一般是 sshd。")
            )
        case .iOS, .iPhone, .iPad:
            return SSHGuide(
                title: tr("在 iPhone / iPad 上开启 SSH"),
                steps: [
                    tr("只有越狱的设备才能开 SSH，没越狱的没有办法。"),
                    tr("在 Sileo 或 Zebra 里搜索并安装「OpenSSH」。"),
                    tr("装好后会自动启动。默认的 root 和 mobile 密码是 alpine，请马上改掉。"),
                ],
                commands: ["passwd"],
                note: tr("改密码的命令要在这台设备的终端里运行。")
            )
        case .android:
            return SSHGuide(
                title: tr("在 Android 上开启 SSH"),
                steps: [
                    tr("安卓没有自带 SSH 服务，需要先安装 Termux。"),
                    tr("在 Termux 里依次运行下面的命令：安装、设置密码、启动。"),
                    tr("Termux 的 SSH 端口是 8022，连接时把端口改成 8022。"),
                ],
                commands: ["pkg install openssh", "passwd", "sshd"]
            )
        case .router, .embedded, .windowsOrNAS, .macFileSharing:
            return SSHGuide(
                title: tr("在路由器 / NAS 上开启 SSH"),
                steps: [
                    tr("用浏览器打开这台设备的管理页面。"),
                    tr("在设置里找「SSH」「终端」或「远程管理」，打开它。比如群晖在：控制面板 → 终端机和 SNMP → 启动 SSH 功能。"),
                    tr("有的设备要先开启管理员 / 开发者模式才会出现这个选项。"),
                ]
            )
        case .smartTV, .printer, .camera:
            return SSHGuide(
                title: tr("这类设备一般不能开 SSH"),
                steps: [
                    tr("智能电视、打印机、摄像头这类设备，通常没有提供 SSH。"),
                    tr("如果是你自己刷过系统的设备，到它的系统里安装 OpenSSH 服务器即可。"),
                ]
            )
        default:
            return SSHGuide(
                title: tr("开启 SSH 的一般方法"),
                steps: [
                    tr("还不确定这是什么设备。先在设备的设置或管理页面里找「SSH」「远程登录」或「远程管理」。"),
                    tr("Mac 在「系统设置 → 通用 → 共享 → 远程登录」；Linux 安装 openssh-server；Windows 安装 OpenSSH 服务器。"),
                ]
            )
        }
    }
}

/// 点没开 SSH 的设备时弹出的说明卡
struct SSHGuideSheet: View {
    let device: SSHDevice
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    var body: some View {
        let guide = SSHGuide.make(for: device.deviceType)
        NavigationStack {
            List {
                Section {
                    DeviceRow(device: device)
                } footer: {
                    Text(tr("这台设备没有开放 SSH（22 端口）。"))
                }

                Section(guide.title) {
                    ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Color.accentColor, in: Circle())
                            Text(step)
                        }
                    }
                }

                if !guide.commands.isEmpty {
                    Section {
                        ForEach(guide.commands, id: \.self) { command in
                            Button {
                                UIPasteboard.general.string = command
                                copied = command
                            } label: {
                                HStack {
                                    Text(command)
                                        .font(.footnote.monospaced())
                                        .foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: copied == command ? "checkmark" : "doc.on.doc")
                                        .foregroundStyle(copied == command ? .green : .secondary)
                                }
                            }
                        }
                    } header: {
                        Text(tr("命令（点一下复制）"))
                    } footer: {
                        if let note = guide.note { Text(note) }
                    }
                } else if let note = guide.note {
                    Section { Text(note).font(.footnote).foregroundStyle(.secondary) }
                }

                Section {
                    Text(tr("开好之后，回到设备页下拉刷新重新扫描，它就会出现在「SSH 设备」里。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(tr("怎么开 SSH"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("关闭")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
