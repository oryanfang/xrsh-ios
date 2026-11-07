import SwiftTerm
import SwiftUI
import UIKit

/// 把 SwiftTerm 的终端视图放进 SwiftUI，并和 SSH 会话互通
struct TerminalRepresentable: UIViewRepresentable {
    let session: TerminalSession
    @AppStorage(SettingsKey.terminalFontSize) private var fontSize = SettingsKey.defaultFontSize

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeUIView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = .white
        view.font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        // 视图刚创建时还没有宽度（只有两列），这时写入文字会被挤成每行两个字符，所以等量好大小再显示。
        // 兜底：万一没收到大小变化，也不能让输出一直显示不出来
        let coordinator = context.coordinator
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak view] in
            if let view { coordinator.attachOutput(to: view) }
        }
        session.onFocusRequest = { [weak view] in _ = view?.becomeFirstResponder() }
        DispatchQueue.main.async { _ = view.becomeFirstResponder() }
        return view
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        // 在设置里改了字体大小，马上跟着变
        if abs(uiView.font.pointSize - CGFloat(fontSize)) > 0.1 {
            uiView.font = UIFont.monospacedSystemFont(ofSize: CGFloat(fontSize), weight: .regular)
        }
    }

    static func dismantleUIView(_ uiView: TerminalView, coordinator: Coordinator) {
        coordinator.session.onOutput = nil
        coordinator.session.onFocusRequest = nil
    }

    @MainActor
    final class Coordinator: NSObject, TerminalViewDelegate {
        let session: TerminalSession

        init(session: TerminalSession) { self.session = session }

        private var outputAttached = false

        func attachOutput(to view: TerminalView) {
            guard !outputAttached else { return }
            outputAttached = true
            session.onOutput = { [weak view] bytes in view?.feed(byteArray: bytes) }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            session.resize(cols: newCols, rows: newRows)
            if newCols >= 10 { attachOutput(to: source) }
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            session.send(data)
        }

        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
        }

        func clipboardRead(source: TerminalView) -> Data? {
            UIPasteboard.general.string.map { Data($0.utf8) }
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            if let url = URL(string: link) { UIApplication.shared.open(url) }
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
