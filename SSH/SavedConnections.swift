import SwiftUI

/// 常用连接：只存地址和用户名。密码和密钥还是在钥匙串里
nonisolated struct SavedConnection: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var user = ""

    var address: String { "\(user)@\(host)" + (port == 22 ? "" : ":\(port)") }
    var title: String { name.isEmpty ? address : name }

    static func list(from data: Data) -> [SavedConnection] {
        (try? JSONDecoder().decode([SavedConnection].self, from: data)) ?? []
    }

    static func encode(_ list: [SavedConnection]) -> Data {
        (try? JSONEncoder().encode(list)) ?? Data()
    }
}

/// 添加或修改一条常用连接
struct SavedConnectionForm: View {
    @AppStorage(SettingsKey.savedConnections) private var savedData = Data()
    @Environment(\.dismiss) private var dismiss
    @State var connection = SavedConnection()
    @State private var port = ""

    private var portNumber: Int? { Int(port).flatMap { (1...65535).contains($0) ? $0 : nil } }
    private var canSave: Bool {
        !connection.host.trimmingCharacters(in: .whitespaces).isEmpty
            && !connection.user.trimmingCharacters(in: .whitespaces).isEmpty && portNumber != nil
    }

    var body: some View {
        Form {
            TextField(tr("名称（可以不填）"), text: $connection.name)
            TextField(tr("主机 / IP"), text: $connection.host)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField(tr("端口"), text: $port)
                .keyboardType(.numberPad)
            TextField(tr("用户名"), text: $connection.user)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .navigationTitle(tr("常用连接"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { port = String(connection.port) }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(tr("保存"), action: save).disabled(!canSave)
            }
        }
    }

    private func save() {
        guard let portNumber else { return }
        connection.port = portNumber
        connection.host = connection.host.trimmingCharacters(in: .whitespaces)
        connection.user = connection.user.trimmingCharacters(in: .whitespaces)
        var list = SavedConnection.list(from: savedData)
        if let index = list.firstIndex(where: { $0.id == connection.id }) {
            list[index] = connection
        } else {
            list.append(connection)
        }
        savedData = SavedConnection.encode(list)
        dismiss()
    }
}
