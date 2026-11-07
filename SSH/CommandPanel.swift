import SwiftUI

/// 点开"常用命令"后升起的面板：分类列出人话版命令，点一条就填进终端的输入行
struct CommandPanel: View {
    /// 要显示的命令分类
    let groups: [QuickCommandGroup]
    /// 命令合集里能不能显示"安装"（只有越狱手机的真终端可以）
    var canInstall = false
    /// 命令合集只显示本机小命令行里有的命令
    var miniShellOnly = false
    /// 点"传文件"时调用；本机命令行没有这一项，传 nil
    var onTransfer: (() -> Void)?
    /// 选中命令后调用（危险命令确认之后才会调用）
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingDangerous: QuickCommand?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        CommandStoreView(canInstall: canInstall, miniShellOnly: miniShellOnly) { command in
                            onPick(command)
                            dismiss()
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "books.vertical.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr("命令合集"))
                                Text(canInstall ? tr("看每个命令是干什么的、怎么用，没有的可以装") : tr("看每个命令是干什么的、怎么用"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let onTransfer {
                    Section(tr("传文件")) {
                        Button {
                            onTransfer()
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.up.arrow.down.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tr("在手机和这台设备之间传文件"))
                                        .foregroundStyle(.primary)
                                    Text(tr("浏览对方的文件夹，下载到手机，或者从手机上传"))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
                ForEach(groups) { group in
                    Section(tr(group.title)) {
                        ForEach(group.items) { item in
                            Button {
                                if item.warning != nil {
                                    pendingDangerous = item
                                } else {
                                    pick(item)
                                }
                            } label: {
                                row(item)
                            }
                        }
                    }
                }
            }
            .navigationTitle(tr("常用命令"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(tr("关闭")) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(tr("点一条会把命令填进终端，按回车才会执行"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.bar)
            }
            .alert(
                tr("确定要填入这条命令吗？"),
                isPresented: Binding(
                    get: { pendingDangerous != nil },
                    set: { if !$0 { pendingDangerous = nil } }
                ),
                presenting: pendingDangerous
            ) { item in
                Button(tr("填入"), role: .destructive) { pick(item) }
                Button(tr("取消"), role: .cancel) {}
            } message: { item in
                Text(tr(item.warning ?? ""))
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func row(_ item: QuickCommand) -> some View {
        let dangerous = item.warning != nil
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tr(item.title))
                    .foregroundStyle(dangerous ? Color.red : Color.primary)
                Text(tr(item.command).trimmingCharacters(in: .whitespaces))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if dangerous {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }
        }
        .contentShape(Rectangle())
    }

    private func pick(_ item: QuickCommand) {
        onPick(tr(item.command))
        dismiss()
    }
}

/// 贴在终端右边缘的小三角：点一下，"常用命令"标签从右边弹出来；再点一下缩回去。
/// 第一次出现时旁边冒一个小气泡提示可以点
struct CommandEdgeTab: View {
    let action: () -> Void

    @AppStorage("seenCommandHint") private var seenHint = false
    @State private var expanded = false
    @State private var showHint = false

    private let height: CGFloat = 44

    var body: some View {
        HStack(spacing: 0) {
            if showHint && !expanded {
                HintBubble(text: tr("点箭头展开常用命令"))
                    .transition(.opacity)
            }
            if expanded {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded = false }
                    action()
                } label: {
                    Text(tr("常用命令"))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(height: height)
                        .background(
                            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
                                .fill(Color.accentColor)
                        )
                }
                .buttonStyle(.plain)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            Button(action: toggle) {
                Image(systemName: expanded ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: height)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: expanded ? 0 : 12,
                            bottomLeadingRadius: expanded ? 0 : 12
                        )
                        .fill(Color.accentColor.opacity(expanded ? 1 : 0.8))
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? tr("收起常用命令") : tr("展开常用命令"))
        }
        .onAppear(perform: playIntro)
    }

    private func toggle() {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
        if showHint { showHint = false }
        seenHint = true
    }

    private func playIntro() {
        guard !seenHint else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard !seenHint else { return }
            withAnimation { showHint = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.3) {
            withAnimation { showHint = false }
            seenHint = true
        }
    }
}

/// 指向右边的小气泡
private struct HintBubble: View {
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            RightTriangle()
                .fill(Color.white)
                .frame(width: 7, height: 12)
        }
        .padding(.trailing, 2)
    }
}

private struct RightTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
