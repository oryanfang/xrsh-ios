import SwiftUI

/// 命令合集：按类别翻看所有命令，点进去看说明和用法；越狱手机上缺的命令可以一键装
struct CommandStoreView: View {
    /// 能不能显示"安装"（只有越狱手机的真终端可以）
    let canInstall: Bool
    /// 只显示本机小命令行里有的命令
    let miniShellOnly: Bool
    /// 选中要填进终端的命令
    let onPick: (String) -> Void

    @State private var installed: Set<String> = []
    @State private var query = ""

    private var keyword: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private func visible(_ item: StoreCommand) -> Bool {
        if miniShellOnly && !item.inMiniShell { return false }
        return keyword.isEmpty
            || item.name.lowercased().contains(keyword)
            || item.summary.lowercased().contains(keyword)
            || tr(item.summary).lowercased().contains(keyword)
    }

    var body: some View {
        List {
            ForEach(CommandStore.groups) { group in
                let items = group.items.filter(visible)
                if !items.isEmpty {
                    Section(tr(group.title)) {
                        ForEach(items) { item in
                            NavigationLink {
                                CommandDetailView(item: item, canInstall: canInstall,
                                                  isInstalled: installed.contains(item.executable), onPick: onPick)
                            } label: {
                                row(item)
                            }
                        }
                    }
                }
            }
            if canInstall {
                Section {
                    Button { onPick("apt search ") } label: {
                        Label(tr("在软件源里搜一个命令"), systemImage: "magnifyingglass")
                    }
                } header: {
                    Text(tr("找不到想要的？"))
                } footer: {
                    Text(tr("命令名和软件包名有时不一样，搜一下就知道它在哪个包里。"))
                }
            }
        }
        .navigationTitle(tr("命令合集"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: tr("搜索命令或功能"))
        .onAppear { if canInstall { installed = CommandStore.installedExecutables() } }
    }

    private func row(_ item: StoreCommand) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.body.monospaced().weight(.medium))
                Text(tr(item.summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if canInstall, item.package != nil, !installed.contains(item.executable) {
                Text(tr("未安装"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// 一个命令的说明页：它是干什么的、常见用法、没装的话怎么装
struct CommandDetailView: View {
    let item: StoreCommand
    let canInstall: Bool
    let isInstalled: Bool
    let onPick: (String) -> Void

    var body: some View {
        List {
            Section {
                Text(tr(item.summary))
                if let note = item.note {
                    Text(tr(note))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                ForEach(item.usages) { usage in
                    Button { onPick(tr(usage.command)) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(tr(usage.title)).foregroundStyle(.primary)
                            Text(tr(usage.command).trimmingCharacters(in: .whitespaces))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text(tr("常见用法"))
            } footer: {
                Text(tr("点一条，会把命令填进终端，按回车才会执行。"))
            }

            if canInstall, let package = item.package {
                Section(tr("安装")) {
                    if isInstalled {
                        Label(tr("这台手机上已经装好了"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button { onPick("apt update && apt install \(package)") } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tr("安装")).foregroundStyle(Color.accentColor)
                                Text("apt update && apt install \(package)")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}
