import SwiftUI

/// 应用内拖拽的全局状态：整个界面据此在按下的瞬间就标出哪些目标可放、哪些不可放。
///
/// 做成单例是有原因的。`.draggable` 的载荷是 autoclosure，SwiftUI 会把它当作
/// modifier 的一部分参与 diff；表达式一旦捕获引用类型（view model、协调器等），
/// 每次布局都会被判定为「变了」而重新注册拖拽源，而这在 macOS 的 List 里发生于
/// NSTableView 的选择回调内，AppKit 会报 reentrant 警告 —— 用户看到的就是
/// 「点一封邮件整个界面刷新一下」。
/// 通过静态成员访问就不构成捕获，载荷表达式里于是只剩值类型。
@MainActor
final class DragMonitor: ObservableObject {
    static let shared = DragMonitor()

    @Published private(set) var active: DragContext?

    /// 用于把单行拖拽扩展成「整组多选」。弱引用，由列表视图在布局时注入。
    weak var appState: AppState?

    private var watcher: Task<Void, Never>?

    private init() {}

    /// 正在拖动邮件（侧栏据此高亮/变灰各账号的标签）。
    var isDraggingThreads: Bool {
        if case .threads = active { return true }
        return false
    }

    /// 正在拖动的邮件所属账号；跨账号多选时为 nil（此时任何标签都不可放）。
    var draggingThreadsAccount: String? {
        guard case .threads(let items) = active else { return nil }
        let accounts = Set(items.map(\.accountID))
        return accounts.count == 1 ? accounts.first : nil
    }

    /// 正在拖动的标签所属账号（列表据此高亮/变灰各行）。
    var draggingLabelAccount: String? {
        guard case .label(let accountID, _, _) = active else { return nil }
        return accountID
    }

    /// 开始拖动列表里的某一行：若它属于当前多选，则整组一起带走。
    @discardableResult
    func beginThreads(from key: SelectedThread) -> [SelectedThread] {
        let selection = appState?.selectedThreads ?? []
        let items = (selection.count > 1 && selection.contains(key)) ? Array(selection) : [key]
        begin(.threads(items))
        return items
    }

    /// 记录拖拽开始。
    ///
    /// macOS 14 的 SwiftUI 没有「拖拽结束」回调，放到无效区域松手不会有任何通知，
    /// 界面会一直停在变灰状态；这里轮询鼠标键状态兜底收尾。
    func begin(_ context: DragContext) {
        active = context
        watcher?.cancel()
        watcher = Task { [weak self] in
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(nanoseconds: 80_000_000)
                if Task.isCancelled { return }
            }
            self?.end()
        }
    }

    /// 结束拖拽，恢复正常显示。
    func end() {
        watcher?.cancel()
        watcher = nil
        active = nil
    }
}

@MainActor
extension ThreadDragPayload {
    /// 拖拽开始时构造载荷，顺带记录拖拽上下文。
    /// 只接收值类型参数——见 `DragMonitor` 顶部关于 autoclosure 捕获的说明。
    static func beginning(_ key: SelectedThread) -> ThreadDragPayload {
        ThreadDragPayload(items: DragMonitor.shared.beginThreads(from: key))
    }
}

@MainActor
extension LabelDragPayload {
    /// 同上：参数全是值类型，表达式里不出现任何引用。
    static func beginning(account: String, labelID: String, labelName: String) -> LabelDragPayload {
        DragMonitor.shared.begin(.label(accountID: account, labelID: labelID, name: labelName))
        return LabelDragPayload(accountID: account, labelID: labelID, labelName: labelName)
    }
}
