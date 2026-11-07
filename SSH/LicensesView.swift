import SwiftUI

/// 开源许可：这个 App 用到的开源库，以及它们的许可原文（原文在 Licenses 文件夹里，随 App 打包）
struct LicensesView: View {
    private struct Library: Identifiable {
        let name: String
        let license: String
        let url: String
        var id: String { name }
    }

    private static let libraries: [Library] = [
        Library(name: "Citadel", license: "MIT", url: "https://github.com/orlandos-nl/Citadel"),
        Library(name: "SwiftTerm", license: "MIT", url: "https://github.com/migueldeicaza/SwiftTerm"),
        Library(name: "BigInt", license: "MIT", url: "https://github.com/attaswift/BigInt"),
        Library(name: "swift-nio", license: "Apache 2.0", url: "https://github.com/apple/swift-nio"),
        Library(name: "swift-nio-ssh", license: "Apache 2.0", url: "https://github.com/apple/swift-nio-ssh"),
        Library(name: "swift-crypto", license: "Apache 2.0", url: "https://github.com/apple/swift-crypto"),
        Library(name: "swift-asn1", license: "Apache 2.0", url: "https://github.com/apple/swift-asn1"),
        Library(name: "swift-log", license: "Apache 2.0", url: "https://github.com/apple/swift-log"),
        Library(name: "swift-atomics", license: "Apache 2.0", url: "https://github.com/apple/swift-atomics"),
        Library(name: "swift-collections", license: "Apache 2.0", url: "https://github.com/apple/swift-collections"),
        Library(name: "swift-system", license: "Apache 2.0", url: "https://github.com/apple/swift-system"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.libraries) { library in
                    NavigationLink {
                        LicenseTextView(library: library.name, url: library.url)
                    } label: {
                        LabeledContent(library.name, value: library.license)
                    }
                }
            } footer: {
                Text(tr("这个 App 使用了以上开源软件，感谢它们的作者。"))
            }
        }
        .navigationTitle(tr("开源许可"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 一个开源库的许可原文
private struct LicenseTextView: View {
    let library: String
    let url: String

    private var text: String {
        guard let file = Bundle.main.url(forResource: "License-\(library)", withExtension: "txt"),
              let content = try? String(contentsOf: file, encoding: .utf8) else {
            return tr("没有找到许可文件。")
        }
        return content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let link = URL(string: url) {
                    Link(url, destination: link)
                        .font(.footnote)
                }
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(library)
        .navigationBarTitleDisplayMode(.inline)
    }
}
