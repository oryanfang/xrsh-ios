import SwiftUI
import UniformTypeIdentifiers

/// 传文件：浏览对方设备的文件夹，点文件下载，点右上角上传
struct SFTPSheet: View {
    @StateObject private var browser: SFTPBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var showGoTo = false
    @State private var typedPath = ""

    init(session: SSHSession) {
        _browser = StateObject(wrappedValue: SFTPBrowser(session: session))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    pathHeader
                }

                Section {
                    if !browser.isAtRoot, !browser.isLoading {
                        Button {
                            Task { await browser.goUp() }
                        } label: {
                            Label(tr("上一级"), systemImage: "arrow.turn.left.up")
                        }
                    }
                    if browser.isLoading {
                        HStack {
                            ProgressView()
                            Text(tr("正在读取…")).foregroundStyle(.secondary).padding(.leading, 8)
                        }
                    } else if browser.entries.isEmpty {
                        Text(tr("这个文件夹是空的"))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(browser.entries) { entry in
                        Button {
                            Task {
                                if entry.isDirectory { await browser.enter(entry) } else { await browser.download(entry) }
                            }
                        } label: {
                            row(entry)
                        }
                    }
                } footer: {
                    Text(tr("点文件下载，下载完可以存到「文件」App 或发给别的 App；点文件夹进入。"))
                }
            }
            .navigationTitle(tr("传文件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("关闭")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showImporter = true
                    } label: {
                        Label(tr("上传"), systemImage: "arrow.up.doc")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let transfer = browser.transfer {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(transfer.isUpload ? tr("正在上传") : tr("正在下载")) \(transfer.name)")
                            .font(.footnote)
                            .lineLimit(1)
                        ProgressView(value: transfer.fraction)
                    }
                    .padding()
                    .background(.bar)
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await browser.upload(urls) }
                }
            }
            .sheet(item: $browser.downloaded) { file in
                ShareSheet(url: file.url)
                    .presentationDetents([.medium, .large])
            }
            .alert(tr("前往路径"), isPresented: $showGoTo) {
                TextField(tr("例如 /var/log 或 ~/Documents"), text: $typedPath)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button(tr("前往")) { Task { await browser.go(to: typedPath) } }
                Button(tr("取消"), role: .cancel) {}
            } message: {
                Text(tr("输入对方设备上的文件夹路径"))
            }
            .alert(tr("完成"), isPresented: Binding(
                get: { browser.notice != nil },
                set: { if !$0 { browser.notice = nil } }
            )) {
                Button(tr("好")) {}
            } message: {
                Text(browser.notice ?? "")
            }
            .alert(tr("出错了"), isPresented: Binding(
                get: { browser.errorText != nil },
                set: { if !$0 { browser.errorText = nil } }
            )) {
                Button(tr("好")) {}
            } message: {
                Text(browser.errorText ?? "")
            }
        }
        .task { await browser.start() }
        .onDisappear { browser.close() }
        .presentationDetents([.large])
    }

    private var pathHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tr("对方设备上的位置"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(browser.path.isEmpty ? "…" : browser.path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            HStack(spacing: 16) {
                Button(tr("前往路径…")) {
                    typedPath = browser.path
                    showGoTo = true
                }
                if !browser.isAtHome, !browser.isLoading {
                    Button(tr("家目录")) {
                        Task { await browser.goHome() }
                    }
                }
            }
            .font(.footnote)
        }
        .padding(.vertical, 2)
    }

    private func row(_ entry: SFTPBrowser.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !entry.isDirectory, let detail = detail(entry) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: entry.isDirectory ? "chevron.right" : "arrow.down.circle")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func detail(_ entry: SFTPBrowser.Entry) -> String? {
        var parts: [String] = []
        if let size = entry.size {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        }
        if let date = entry.modified {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 系统的分享面板：里面有"存储到文件"、发送给其他 App 等
private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
