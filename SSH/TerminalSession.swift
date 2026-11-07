import Combine
import Foundation

/// 终端页里的一次会话。SSH 连接和本机命令行都继承它，共用同一套终端界面
@MainActor
class TerminalSession: ObservableObject {
    enum State: Equatable {
        case connecting
        case connected
        case failed(String)
        case closed
    }

    @Published var state = State.connecting

    /// 导航栏标题
    var title: String { tr("终端") }
    /// 本机命令行（没有"重新连接"，只有"重新进入"）
    var isLocal: Bool { false }
    /// 越狱手机上的真 shell（命令按 iOS 越狱环境来，不是 Linux）
    var isDeviceShell: Bool { false }
    /// 只支持 App 自带小命令行里的那部分命令（面板里只显示它能跑的）
    var limitedCommands: Bool { false }
    /// 重新连接时要预填的主机；本机会话为 nil
    var reconnectHost: String? { nil }

    /// 终端视图设置后，输出会交给它；设置之前产生的输出先缓存
    var onOutput: ((ArraySlice<UInt8>) -> Void)? {
        didSet {
            guard let onOutput else { return }
            pending.forEach(onOutput)
            pending = []
        }
    }

    /// 终端视图设置：让它重新拿到键盘焦点
    var onFocusRequest: (() -> Void)?

    private var pending: [ArraySlice<UInt8>] = []

    /// 把要显示的字节交给终端视图
    func receive(_ bytes: ArraySlice<UInt8>) {
        if let onOutput {
            onOutput(bytes)
        } else {
            pending.append(bytes)
        }
    }

    func requestFocus() { onFocusRequest?() }

    /// 键盘输入
    func send(_ bytes: ArraySlice<UInt8>) {}
    func resize(cols: Int, rows: Int) {}
    func close() {}
}
