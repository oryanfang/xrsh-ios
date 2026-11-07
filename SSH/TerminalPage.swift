import SwiftUI

struct TerminalPage: View {
    @ObservedObject var model: TerminalModel
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue
    @AppStorage(SettingsKey.keyRevision) private var keyRevision = 0
    @State private var askKeyLogin = false
    @State private var settingUpKey = false
    @State private var keyMessage: String?

    /// 已连上的 SSH 会话（可以设置或取消免密登录）
    private var keyCandidate: SSHSession? {
        _ = keyRevision
        guard let ssh = model.session as? SSHSession, ssh.state == .connected else { return nil }
        return ssh
    }

    var body: some View {
        let _ = language
        NavigationStack {
            Group {
                if let session = model.session {
                    SessionView(session: session, model: model)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "terminal")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text(tr("还没有连接"))
                            .font(.title2.weight(.semibold))
                        Text(tr("进入本机终端，或者连接一台 SSH 设备"))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button(tr("进入本机终端")) { model.startLocal() }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 8)
                        Button(tr("新建 SSH 连接")) { model.requestConnect(host: "") }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(model.session?.title ?? tr("终端"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let ssh = keyCandidate {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            askKeyLogin = true
                        } label: {
                            if settingUpKey {
                                ProgressView()
                            } else if ssh.hasKeyLogin {
                                Label(tr("免密登录"), systemImage: "star.fill")
                                    .foregroundStyle(.yellow)
                            } else {
                                Label(tr("免密登录"), systemImage: "star")
                            }
                        }
                        .disabled(settingUpKey)
                        .confirmationDialog(
                            ssh.hasKeyLogin ? tr("取消这台设备的免密登录？") : tr("给这台设备设置免密登录？"),
                            isPresented: $askKeyLogin, titleVisibility: .visible
                        ) {
                            if ssh.hasKeyLogin {
                                Button(tr("取消免密登录"), role: .destructive) {
                                    Keychain.deletePrivateKey(ssh.keyAccount)
                                }
                            } else {
                                Button(tr("开始设置")) { setUpKey(ssh) }
                            }
                            Button(tr("返回"), role: .cancel) {}
                        } message: {
                            Text(ssh.hasKeyLogin
                                 ? tr("会删除这台手机上保存的密钥，设备列表里的星标消失，之后连接要用密码。对方设备上的公钥不会被删除。")
                                 : tr("会生成一把密钥，把公钥添加到对方的 ~/.ssh/authorized_keys；私钥只保存在这台手机的钥匙串里。以后连接这台设备不用输密码。"))
                        }
                    }
                }
                if model.session != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            model.disconnect()
                        } label: {
                            Label(tr("断开"), systemImage: "xmark.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $model.showConnect) {
                ConnectSheet(model: model)
            }
            .alert(tr("免密登录"), isPresented: Binding(
                get: { keyMessage != nil },
                set: { if !$0 { keyMessage = nil } }
            )) {
                Button(tr("好")) {}
            } message: {
                Text(keyMessage ?? "")
            }
        }
    }
}

extension TerminalPage {
    fileprivate func setUpKey(_ ssh: SSHSession) {
        settingUpKey = true
        Task {
            do {
                try await ssh.enableKeyLogin()
                keyMessage = tr("设置好了。以后连接这台设备不用输密码，设备列表里它会显示黄色五角星。")
            } catch {
                keyMessage = tr("设置失败：{0}", (error as? LocalizedError)?.errorDescription ?? String(describing: error))
            }
            settingUpKey = false
        }
    }
}

/// 一次会话的界面：终端 + 连接中 / 出错 / 已断开的提示
private struct SessionView: View {
    @ObservedObject var session: TerminalSession
    @ObservedObject var model: TerminalModel
    @State private var showCommands = false
    @State private var showTransfer = false

    var body: some View {
        ZStack {
            TerminalRepresentable(session: session)
                .background(Color.black)
            switch session.state {
            case .connecting:
                overlay {
                    ProgressView(tr("正在连接…"))
                }
            case .failed(let message):
                overlay {
                    Text(tr("连接失败")).font(.headline)
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    reconnectButton
                }
            case .closed:
                overlay {
                    Text(session.isLocal ? tr("已退出本机终端") : tr("连接已断开")).font(.headline)
                    reconnectButton
                }
            case .connected:
                EmptyView()
            }
        }
        // 右边缘的小三角，不占用终端的位置，需要时点开
        .overlay(alignment: .bottomTrailing) {
            if session.state == .connected {
                CommandEdgeTab { showCommands = true }
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showCommands) {
            CommandPanel(
                groups: CommandCatalog.groups(for: session),
                canInstall: session.isDeviceShell,
                miniShellOnly: session.limitedCommands,
                onTransfer: session is SSHSession ? {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { showTransfer = true }
                } : nil
            ) { command in
                // 等面板收起之后再填，只填入输入行，不按回车
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    session.send(Array(command.utf8)[...])
                    session.requestFocus()
                }
            }
        }
        .sheet(isPresented: $showTransfer) {
            if let ssh = session as? SSHSession {
                SFTPSheet(session: ssh)
            }
        }
    }

    private var reconnectButton: some View {
        Button(session.isLocal ? tr("重新进入") : tr("重新连接")) {
            if let host = session.reconnectHost {
                // 连接失败多半是密码或密钥不对，弹出面板让用户改；只是断开了就直接重连
                if case .failed = session.state { model.requestConnect(host: host) } else { model.connectQuick(host: host) }
            } else {
                model.startLocal()
            }
        }
        .buttonStyle(.borderedProminent)
    }

    private func overlay<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12, content: content)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial)
    }
}
