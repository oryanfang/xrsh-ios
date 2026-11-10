import SwiftUI
import UIKit

private enum AppTab: CaseIterable {
    case devices, terminal, settings

    var title: String {
        switch self {
        case .devices: tr("设备")
        case .terminal: tr("终端")
        case .settings: tr("设置")
        }
    }

    var icon: String {
        switch self {
        case .devices: "network"
        case .terminal: "terminal"
        case .settings: "gearshape"
        }
    }

    var selectedIcon: String {
        switch self {
        case .devices: "network"
        case .terminal: "terminal.fill"
        case .settings: "gearshape.fill"
        }
    }
}

struct MainTabView: View {
    let scanner: NetworkScanner
    @State private var selection: AppTab = .devices
    @StateObject private var terminal: TerminalModel
    @State private var keyboardVisible = false
    /// 语言一变，设备页和设置页整个重建，文字就跟着换
    @AppStorage(AppLanguage.storageKey) private var language = AppLanguage.system.rawValue

    init(scanner: NetworkScanner) {
        self.scanner = scanner
        _terminal = StateObject(wrappedValue: TerminalModel(scanner: scanner))
    }

    var body: some View {
        // 三个页面一直保留在视图树里，只切换显示，这样切页后各页的状态不会丢
        VStack(spacing: 0) {
            ZStack {
                page(.devices) {
                    ContentView(
                        scanner: scanner,
                        onConnect: { ip in
                            terminal.connectQuick(host: ip)
                            selection = .terminal
                        },
                        onConnectSaved: { connection in
                            terminal.connectSaved(connection)
                            selection = .terminal
                        },
                        onLocalTerminal: {
                            // 已经有本机会话就直接回去，没有才新开
                            if !(terminal.session?.isLocal ?? false) || terminal.session?.state == .closed {
                                terminal.startLocal()
                            }
                            selection = .terminal
                        }
                    )
                    .id(language)
                }
                page(.terminal) { TerminalPage(model: terminal) }
                page(.settings) { SettingsView(scanner: scanner).id(language) }
            }
            .task {
                // 大退前连着设备的话，重新打开直接回到终端页并接上
                if terminal.resumeLastSession() { selection = .terminal }
            }
            // 标签栏直接排在页面下面（不用 safeAreaInset，否则列表最后一行会被它压住）。
            // 键盘弹出时收起标签栏，否则它会浮在键盘上面挡住终端输入
            if !keyboardVisible {
                TabBar(selection: $selection)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }

    private func page<Content: View>(_ tab: AppTab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(selection == tab ? 1 : 0)
            .allowsHitTesting(selection == tab)
            .accessibilityHidden(selection != tab)
    }
}

/// 贴在底部的平面标签栏，只有图标，选中的是主色、没选中的是灰色
private struct TabBar: View {
    @Binding var selection: AppTab

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 0) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    let isSelected = selection == tab
                    Button {
                        selection = tab
                    } label: {
                        Image(systemName: isSelected ? tab.selectedIcon : tab.icon)
                            .font(.system(size: 22, weight: isSelected ? .semibold : .regular))
                            .frame(maxWidth: .infinity, minHeight: 49)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                    .accessibilityLabel(tab.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
        .background(Color(.systemBackground).ignoresSafeArea(edges: .bottom))
    }
}

#Preview {
    MainTabView(scanner: NetworkScanner())
}
