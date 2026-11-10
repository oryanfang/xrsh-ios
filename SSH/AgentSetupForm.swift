import SwiftUI

/// 填接口地址、模型名、API Key。第一次用 /xr 和设置页共用
struct AgentSetupForm: View {
    var onCancel: (() -> Void)?
    var onDone: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var baseURL = AgentSettings.baseURL
    @State private var model = AgentSettings.model
    @State private var key = ""
    @State private var hasKey = AgentSettings.apiKey != nil

    private var isHTTP: Bool {
        baseURL.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("http://")
    }

    private var canSave: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !model.trimmingCharacters(in: .whitespaces).isEmpty
            && (hasKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        Form {
            Section {
                TextField(tr("接口地址，如 https://api.openai.com/v1"), text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField(tr("模型名"), text: $model)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(hasKey ? tr("API Key（已保存，留空不改）") : tr("API Key"), text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Key 只存在这台手机的钥匙串里。你说的话、连着的设备名、设备列表、最近的终端输出和跑过的命令的输出，会发给这个地址；看起来像密码和密钥的内容会先隐藏。"))
                    if isHTTP {
                        Text(tr("这个地址不是 https，Key 和内容会明文传输。")).foregroundStyle(.orange)
                    }
                }
            }
            if hasKey {
                Section {
                    Button(tr("清除 API Key"), role: .destructive) {
                        Keychain.deleteAgentAPIKey()
                        hasKey = false
                        key = ""
                    }
                }
            }
        }
        .navigationTitle(tr("连接 AI"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("取消"), action: onCancel)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(tr("保存"), action: save).disabled(!canSave)
            }
        }
    }

    private func save() {
        AgentSettings.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        AgentSettings.model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let newKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newKey.isEmpty { Keychain.saveAgentAPIKey(newKey) }
        if let onDone { onDone() } else { dismiss() }
    }
}
