import SwiftUI

struct ConnectSheet: View {
    @ObservedObject var model: TerminalModel
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = "22"
    @State private var username = UserDefaults.standard.string(forKey: "lastSSHUser") ?? ""
    @State private var password = ""
    @State private var remember = true
    @State private var useKey = true
    @State private var saveToList = false
    @AppStorage(SettingsKey.savedConnectionsEnabled) private var savedEnabled = false
    @AppStorage(SettingsKey.savedConnections) private var savedData = Data()

    private var portNumber: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var canConnect: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && portNumber != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(tr("主机 / IP"), text: $host)
                        .keyboardType(.URL)
                    TextField(tr("端口"), text: $port)
                        .keyboardType(.numberPad)
                    TextField(tr("用户名"), text: $username)
                    SecureField(tr("密码"), text: $password)
                    Toggle(tr("记住密码"), isOn: $remember)
                    if savedEnabled {
                        Toggle(tr("保存到常用连接"), isOn: $saveToList)
                    }
                } footer: {
                    Text(tr("密码保存在系统钥匙串里，只存在这台手机上。"))
                }
                if hasKey {
                    Section {
                        Toggle(isOn: $useKey) {
                            Label(tr("使用免密登录"), systemImage: "star.fill")
                                .foregroundStyle(.primary, .yellow)
                        }
                    } footer: {
                        Text(tr("已给这台设备设置了免密登录，开着的话密码可以留空；登不上时会自动改用上面的密码。"))
                    }
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle(tr("新建连接"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(tr("连接"), action: connect)
                        .disabled(!canConnect)
                }
            }
            .onAppear {
                host = model.prefillHost
                port = String(model.prefillPort)
                if !model.prefillUser.isEmpty { username = model.prefillUser }
                loadSavedPassword()
            }
            .onChange(of: username) { loadSavedPassword() }
        }
    }

    private var account: String? {
        guard let portNumber else { return nil }
        return Keychain.account(user: username, host: host.trimmingCharacters(in: .whitespaces), port: portNumber)
    }

    private var hasKey: Bool {
        account.map { Keychain.privateKey(for: $0) != nil } ?? false
    }

    private func loadSavedPassword() {
        guard password.isEmpty, let account, let saved = Keychain.password(for: account) else { return }
        password = saved
    }

    private func connect() {
        guard let portNumber, let account else { return }
        let host = host.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(username, forKey: "lastSSHUser")
        if remember {
            Keychain.save(password, for: account)
        } else {
            Keychain.delete(account)
        }
        if savedEnabled, saveToList {
            var list = SavedConnection.list(from: savedData)
            if !list.contains(where: { $0.host == host && $0.port == portNumber && $0.user == username }) {
                list.append(SavedConnection(host: host, port: portNumber, user: username))
                savedData = SavedConnection.encode(list)
            }
        }
        model.start(host: host, port: portNumber, username: username, password: password, useKey: useKey)
        dismiss()
    }
}

/// 把 SwiftTerm 的终端视图放进 SwiftUI，并和 SSH 会话互通
