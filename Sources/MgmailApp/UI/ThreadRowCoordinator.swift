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
/// 列表行的身份：会话 key 再加上「这行有没有标签 chip」。
///
/// macOS 的 List 底下是 NSTableView，行高按行身份缓存：身份不变时只换内容，
/// 高度沿用旧值 —— 给一封原本没标签的邮件打上标签，chip 那一行就会被行的下边缘裁掉。
/// 身份只在「有 chip / 没 chip」之间翻转，正对应唯一一次真实的高度变化；
/// 已读、旗标这些不改高度的变化不参与，免得白白重建整行。
struct ThreadRowItem: Identifiable {
    /// 身份是个现成的值，不拼字符串：List 每次比对都要把所有行的 id 取一遍。
    struct ID: Hashable {
        let key: SelectedThread
        let hasChips: Bool
    }

    let summary: ThreadSummary
    let hasChips: Bool
    var id: ID { ID(key: summary.key, hasChips: hasChips) }
}

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

    /// 行内标签 chip 用的映射。缓存在这里而不是每次布局现算：
    /// 字典是堆分配的，现算出来的新字典即使内容相同，缓冲区地址也不同，
    /// SwiftUI 会据此认为每一行都变了，于是重建整行、重新注册菜单/手势/拖放 —— 又是重入。
    private(set) var labelMap: [String: GmailLabel] = [:]

    /// 内容真的变了才替换，保持字典实例稳定。
    func updateLabelMap(_ fresh: [String: GmailLabel]) {
        guard fresh != labelMap else { return }
        labelMap = fresh
        labelMapVersion &+= 1
        // 顺手按账号拆成集合，判断「这行有没有 chip」时就不必为每个标签现拼一个键
        userLabelIDs = [:]
        labelsByAccount = [:]
        for (key, label) in fresh {
            let parts = key.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            userLabelIDs[String(parts[0]), default: []].insert(String(parts[1]))
            labelsByAccount[String(parts[0]), default: []].append(label)
        }
        for account in labelsByAccount.keys {
            labelsByAccount[account]?.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    /// 某个账号的用户标签，按名称排好（右键里的标签子菜单用）。
    func sortedLabels(account: String) -> [GmailLabel] {
        labelsByAccount[account] ?? []
    }

    private var labelsByAccount: [String: [GmailLabel]] = [:]

    private var labelMapVersion = 0
    /// 各账号的用户标签 id（`labelMap` 的另一种摆法，跟着它一起换）。
    private var userLabelIDs: [String: Set<String>] = [:]

    // MARK: - 列表行

    /// 上一次算出来的行，连同它是照着哪个版本的列表、哪个版本的标签算的。
    private var rowItemsCache: (model: ObjectIdentifier, summaries: Int, labels: Int, items: [ThreadRowItem])?

    /// 交给 `List` 的那一排行。
    ///
    /// 列表内容和标签都没变时，原样交回上一次那个数组，不重新算。中栏的 body 重跑得
    /// 远比列表内容变化勤——点一下选中、右栏换一封、任何一处状态动一下都会来一遍——
    /// 每次都把上万行重新过一遍、每行现拼一个 id，光这一步就够让「点一下」慢半拍；
    /// 而数组还是同一个时，SwiftUI 那边的比对也几乎不花时间。
    func rowItems() -> [ThreadRowItem] {
        guard let model else { return [] }
        let owner = ObjectIdentifier(model)
        if let cache = rowItemsCache, cache.model == owner,
           cache.summaries == model.summariesVersion, cache.labels == labelMapVersion {
            return cache.items
        }
        let items = model.summaries.map { summary in
            let mine = userLabelIDs[summary.accountID]
            return ThreadRowItem(summary: summary,
                                 hasChips: mine.map { ids in summary.labelIds.contains { ids.contains($0) } } ?? false)
        }
        rowItemsCache = (owner, model.summariesVersion, labelMapVersion, items)
        return items
    }

    /// 选中的行最后一次出现在列表里时的下标（多选取最靠下的那个，和删除时的算法一致）。
    ///
    /// 删除、归档后要选「下一封」，靠的是被删那行在列表里的位置；可它有时已经不在列表里了：
    /// 开着「仅未读」时，一封邮件点开即已读、当场就从列表里消失，右栏却还看着它——
    /// 这时按删除，按行去找找不到，选择就只能清空，用户看到的是右栏变成「未选择邮件」，
    /// 得回列表再点一下。记住它最后待过的位置，被删时就选补到这个位置上的那一行。
    private var anchorIndex: Int?

    /// 由列表每次布局时调用：选中的行还在列表里就更新位置，不在了就留着上一次的。
    func noteLayout(summaries: [ThreadSummary], selection: Set<SelectedThread>) {
        guard !selection.isEmpty else { return }
        let index: Int?
        if selection.count == 1, let only = selection.first {
            // 只选了一封（绝大多数时候）：从头找到它就停。倒着找的话，
            // 看的是列表顶上那几封时，每次布局都要把整张列表从尾巴扫到头。
            index = summaries.firstIndex { $0.id == only.threadID && $0.accountID == only.accountID }
        } else {
            index = summaries.indices.last(where: { selection.contains(summaries[$0].key) })
        }
        guard let index else { return }
        anchorIndex = index
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
    func moveToInbox(_ summary: ThreadSummary) { performMoveToInbox(targets(summary)) }
    func trash(_ summary: ThreadSummary) { performTrash(targets(summary)) }

    /// 这一行现在在收件箱、归档，还是废纸篓——决定行上摆哪几个动作。
    func placement(_ summary: ThreadSummary) -> MailPlacement {
        MailPlacement(labels: summary.labelIds)
    }

    /// 双击（或右键「在新窗口中打开」）：把这一行拎到独立窗口里。
    ///
    /// 只作用于点中的那一行，不跟着多选走——双击的意思是「就看这一封」。
    func openInWindow(_ key: SelectedThread) {
        appState.requestDetach(account: key.accountID, id: key.threadID)
    }

    /// 右键「查看原始邮件」：开一扇原文窗口。
    ///
    /// 原文是一封信一份，而按会话显示时这一行代表的是一串——取最新的那一封。
    /// 想看串里更早的某一封，从右栏那封卡片上的右键菜单进，那儿指的就是它自己。
    func showRawSource(_ summary: ThreadSummary) {
        guard let messageID = model.messageIDs(for: summary.key).last else { return }
        appState.requestRawSource(account: summary.accountID, messageID: messageID)
    }

    /// 双击表格第 `row` 行。
    ///
    /// 表格给的是行号（见 `ThreadListDoubleClick`），这里按那张表自己的 `model` 翻译成那一封邮件。
    /// 列表末尾还有一行「已回溯至 …」的页脚，它的行号越界，正好被这里挡掉。
    func openInWindow(rowAt row: Int, in model: ThreadListModel) {
        guard model.summaries.indices.contains(row) else { return }
        openInWindow(model.summaries[row].key)
    }

    // MARK: - 批量执行（含删除/归档后自动选中下一封）
    //
    // 三个动作都先按邮件当前的状态筛一遍：多选里混着收件箱、归档和废纸篓里的邮件时，
    // 每个按钮只作用于它说得通的那部分——不会去删已经在废纸篓里的（那是永久删除），
    // 也不会去归档一封根本不在收件箱的。

    func performTrash(_ keys: [SelectedThread]) {
        let targets = keys.filter { model.placement(of: $0).canTrash }
        guard !targets.isEmpty else { return }
        let advance = advanceSelectionIfNeeded(removing: targets)
        Task { await model.trashMany(targets) }
        applyAdvance(advance, removed: targets)
    }

    func performArchive(_ keys: [SelectedThread]) {
        let targets = keys.filter { model.placement(of: $0).canArchive }
        guard !targets.isEmpty else { return }
        let leaving = targets.filter { !model.remainsVisible($0, remove: ["INBOX"]) }
        let advance = advanceSelectionIfNeeded(removing: leaving)
        Task { await model.mutateMany(targets, remove: ["INBOX"]) }
        applyAdvance(advance, removed: leaving)
    }

    func performMoveToInbox(_ keys: [SelectedThread]) {
        let targets = keys.filter { model.placement(of: $0).canMoveToInbox }
        guard !targets.isEmpty else { return }
        let leaving = targets.filter {
            !model.remainsVisible($0, add: MailPlacement.inboxAdd,
                                  remove: MailPlacement.inboxRemove + ["TRASH"])
        }
        let advance = advanceSelectionIfNeeded(removing: leaving)
        Task { await model.moveToInboxMany(targets) }
        applyAdvance(advance, removed: leaving)
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
        guard let last = removedIdxs.max() else {
            // 被删的已经不在列表里（见 anchorIndex）：选补到它原来位置上的那一行
            guard let anchor = anchorIndex, !list.isEmpty else { return .some(nil) }
            return .some(list[min(anchor, list.count - 1)].key)
        }
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
