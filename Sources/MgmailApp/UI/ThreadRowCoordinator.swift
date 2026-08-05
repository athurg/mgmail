import SwiftUI

/// 列表行的动作中枢。
///
/// 存在的理由是性能而非抽象：SwiftUI 的 List 在 macOS 上由 NSTableView 支撑，
/// 行视图只要带了闭包字段，SwiftUI 就无法判断它有没有变，于是每次改选中都会重建每一行、
/// 连带重新注册行上的拖放；而这发生在 NSTableView 的选择回调里，AppKit 会报
/// 「reentrant operation in its NSTableView delegate」，用户看到的就是点一封邮件整个界面刷一下。
///
/// 把动作收进这个长期存活的对象后，行视图的字段全是可比较的值加一个稳定的引用，
/// SwiftUI 比较下来没变化就整行跳过，重入随之消失。
@MainActor
final class ThreadRowCoordinator: ObservableObject {
    /// 单例。行视图必须通过静态成员访问它：一旦把它作为字段存进行里，
    /// 行上各种 modifier 的闭包就会捕获这个引用，SwiftUI 每次布局都判定 modifier 变了、
    /// 重新注册菜单/手势/拖放，而这在 NSTableView 的选择回调里就是重入。
    static let shared = ThreadRowCoordinator()

    private init() {}

    /// 拖入标签时高亮的目标行。行只接收「我是不是目标」的布尔值，不订阅这里。
    @Published var dropTargetKey: SelectedThread?

    /// 由视图在每次布局时刷新的引用（都是长期存活的对象，指针稳定）。
    var model: ThreadListModel!
    var appState: AppState!

    /// 每行在列表坐标系里的位置，供覆盖其上的拖拽层做命中判断。
    /// 普通 var：布局时频繁更新，不该触发任何刷新。
    var rowFrames: [SelectedThread: CGRect] = [:]

    /// 列表坐标 → 该处是哪一行。
    func row(at point: CGPoint) -> SelectedThread? {
        rowFrames.first { $0.value.contains(point) }?.key
    }

    /// 行内标签 chip 用的映射。缓存在这里而不是每次布局现算：
    /// 字典是堆分配的，现算出来的新字典即使内容相同，缓冲区地址也不同，
    /// SwiftUI 会据此认为每一行都变了，于是重建整行、重新注册菜单/手势/拖放 —— 又是重入。
    private(set) var labelMap: [String: GmailLabel] = [:]

    /// 内容真的变了才替换，保持字典实例稳定。
    func updateLabelMap(_ fresh: [String: GmailLabel]) {
        if fresh != labelMap { labelMap = fresh }
    }

    // MARK: - 作用对象

    /// 行上手势/菜单的作用对象：若该行属于当前多选，则作用于整组，否则仅该行。
    func targets(_ summary: ThreadSummary) -> [SelectedThread] {
        if appState.selectedThreads.count > 1, appState.selectedThreads.contains(summary.key) {
            return Array(appState.selectedThreads)
        }
        return [summary.key]
    }

    // MARK: - 行操作

    func toggleStar(_ summary: ThreadSummary) {
        let keys = targets(summary)
        Task { await model.mutateMany(keys, add: summary.isStarred ? [] : ["STARRED"],
                                      remove: summary.isStarred ? ["STARRED"] : []) }
    }

    func toggleUnread(_ summary: ThreadSummary) {
        let keys = targets(summary)
        Task { await model.mutateMany(keys, add: summary.isUnread ? [] : ["UNREAD"],
                                      remove: summary.isUnread ? ["UNREAD"] : []) }
    }

    /// 右键菜单里勾/去一个标签（作用于整组多选或单行）。
    func toggleLabel(_ labelID: String, on summary: ThreadSummary, currentlyOn: Bool) {
        let keys = targets(summary)
        Task { await model.mutateMany(keys, add: currentlyOn ? [] : [labelID],
                                      remove: currentlyOn ? [labelID] : []) }
    }

    func archive(_ summary: ThreadSummary) { performArchive(targets(summary)) }
    func trash(_ summary: ThreadSummary) { performTrash(targets(summary)) }

    func loadMoreIfNeeded(after summary: ThreadSummary) {
        guard summary.id == model.summaries.last?.id else { return }
        Task { await model.loadMore() }
    }

    // MARK: - 批量执行（含删除/归档后自动选中下一封）

    func performTrash(_ keys: [SelectedThread]) {
        let advance = advanceSelectionIfNeeded(removing: keys)
        Task { await model.trashMany(keys) }
        applyAdvance(advance, removed: keys)
    }

    func performArchive(_ keys: [SelectedThread]) {
        let advance = advanceSelectionIfNeeded(removing: keys)
        Task { await model.mutateMany(keys, remove: ["INBOX"]) }
        applyAdvance(advance, removed: keys)
    }

    func markRead(_ keys: [SelectedThread]) {
        Task { await model.mutateMany(keys, remove: ["UNREAD"]) }
    }

    func star(_ keys: [SelectedThread]) {
        Task { await model.mutateMany(keys, add: ["STARRED"]) }
    }

    /// 若删除/归档影响了当前选择，计算应自动选中的下一封（否则返回 nil 表示不改选择）。
    private func advanceSelectionIfNeeded(removing keys: [SelectedThread]) -> SelectedThread?? {
        let keySet = Set(keys)
        guard !keySet.isDisjoint(with: appState.selectedThreads) else { return .none } // 不影响选择
        // 找被删项在列表中的最大下标，选其后第一个未被删的；没有则选其前一个
        let list = model.summaries
        let removedIdxs = list.indices.filter { keySet.contains(list[$0].key) }
        guard let last = removedIdxs.max() else { return .some(nil) }
        if let n = (last + 1 ..< list.count).first(where: { !keySet.contains(list[$0].key) }) {
            return .some(list[n].key)
        }
        if let p = (0 ..< last).reversed().first(where: { !keySet.contains(list[$0].key) }) {
            return .some(list[p].key)
        }
        return .some(nil)
    }

    private func applyAdvance(_ advance: SelectedThread??, removed keys: [SelectedThread]) {
        switch advance {
        case .none:
            // 不影响选择：仅把被删项从选择集移除（通常本就不在其中）
            appState.selectedThreads.subtract(Set(keys))
        case .some(let next):
            appState.selectedThreads = next.map { [$0] } ?? []
        }
    }

    // MARK: - 拖放

    /// 拖动中的标签能否落到这一行：只看该行自己的账号。
    /// 刻意不看多选（不走 `targets`）——那会让每次改选中都要重算所有行。
    func labelDropAffinity(_ summary: ThreadSummary) -> DropAffinity {
        guard let account = DragMonitor.shared.draggingLabelAccount else { return .neutral }
        return summary.accountID == account ? .enabled : .disabled
    }

    func setDropTarget(_ inside: Bool, key: SelectedThread) {
        if inside { dropTargetKey = key }
        else if dropTargetKey == key { dropTargetKey = nil }
    }

    /// 接收拖来的标签：作用于整组多选，若多选跨了账号则只作用于落点这一行。
    func acceptLabelDrop(_ providers: [NSItemProvider], on summary: ThreadSummary) -> Bool {
        let group = targets(summary)
        DragMonitor.shared.end()
        dropTargetKey = nil
        Task {
            guard let payload = await LabelDragPayload.decode(from: providers),
                  summary.accountID == payload.accountID else { return }
            let items = group.allSatisfy { $0.accountID == payload.accountID } ? group : [summary.key]
            await model.mutateMany(items, add: [payload.labelID])
        }
        return true
    }
}
