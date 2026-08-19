import SwiftUI

/// 中栏：会话列表。
struct ThreadListView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var mailStore: MailStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = ThreadListModel()
    /// 全局设置：是否按会话显示邮件。默认关闭（每行一封独立邮件）。
    @AppStorage(SettingsKey.conversationView) private var conversationView = false
    /// 已读/未读过滤（右上角过滤器，记住上次选择）。
    @AppStorage(SettingsKey.readFilter) private var readFilterRaw = ReadFilter.all.rawValue
    /// 搜索范围（记住上次选择：一直想搜全部的人不必每次都改一遍）。
    @AppStorage(SettingsKey.searchScope) private var searchScopeRaw = SearchScope.mailbox.rawValue
    /// 搜索框里的内容。刻意不持久化——搜索是一次性的动作，
    /// 下次打开应用还带着上次那个词，只会让人以为邮件丢了。
    @State private var searchText = ""
    /// 真正交给列表的搜索词。跟着输入延后一点点，见 `searchDebounce`。
    @State private var debouncedSearch = ""
    /// 行的动作中枢（长期存活，保证行视图的字段稳定可比较，详见 ThreadRowCoordinator）。
    @ObservedObject private var rows = ThreadRowCoordinator.shared
    /// 拖拽状态：只有列表和侧栏订阅它，拖动时不会连累详情栏重绘。
    @ObservedObject private var drag = DragMonitor.shared
    /// 冷启动的第一次刷新还没跑完（此时列表空白该显示转圈而不是「没有邮件」）。
    @State private var isFirstLoad = true
    /// 冷启动那次全账号刷新已经跑过了，后面切分组不该再来一遍。
    @State private var didColdStart = false

    private var readFilter: ReadFilter { ReadFilter(rawValue: readFilterRaw) ?? .all }
    /// 当前范围。存的账号若已经不在（账号被移除、或换了分组），回落到「当前邮箱」——
    /// 让范围条停在一个已经不存在的账号上，搜出来永远是空的。
    private var searchScope: SearchScope {
        let scope = SearchScope(rawValue: searchScopeRaw) ?? .mailbox
        if case .account(let id) = scope,
           !appState.accounts.contains(where: { $0.id == id }) {
            return .mailbox
        }
        return scope
    }

    private var searchScopeBinding: Binding<SearchScope> {
        Binding(get: { searchScope }, set: { searchScopeRaw = $0.rawValue })
    }

    /// 范围条上列哪几个账号：当前分组里的这些，和侧栏对得上。
    /// 分组之外的账号走「所有账号」那一档。
    private var scopeAccounts: [Account] { appState.activeAccounts }

    /// 每敲一个字就把整个池子分组、排序一遍太贵，隔一小会儿再算。
    /// 这点延迟在输入过程中察觉不到，停手之后结果是立刻出来的。
    private static let searchDebounce: Duration = .milliseconds(160)

    /// 当前选择涉及的账号（聚合视图为当前分组内账号）。
    private var selectionAccounts: [String] {
        guard let sel = appState.selection else { return [] }
        if let acc = sel.accountID { return [acc] }
        return appState.activeAccounts.map(\.id)
    }

    /// 这一次列表计算涉及哪些账号。
    ///
    /// 不搜的时候就是当前选择涉及的那些；搜索时按范围放宽——这是三档范围里
    /// 后两档的全部含义（归属判断那半边在 `ThreadListModel.activeQuery`）。
    private var searchAccounts: [String] {
        guard !debouncedSearch.isEmpty else { return selectionAccounts }
        switch searchScope {
        case .mailbox: return selectionAccounts
        case .account(let id): return [id]
        case .all: return appState.accounts.map(\.id)
        }
    }

    /// 用户标签映射（"账号\t labelId" → 标签），跨账号，供行内 chip 使用。
    private var labelMap: [String: GmailLabel] {
        var map: [String: GmailLabel] = [:]
        for account in searchAccounts {
            for label in labelStore.userLabels(for: account) {
                map["\(account)\t\(label.id)"] = label
            }
        }
        return map
    }

    var body: some View {
        content
        .navigationTitle(appState.selection?.labelName ?? "收件箱")
        // 这里不再放刷新按钮：自动刷新有定时器，手动刷新在侧栏账号行上，
        // 而「正在联网」由窗口底部的活动栏统一交代。
        //
        // 搜索框摆在窗口右上角（仿 Apple Mail），不占列表的地方。中栏的工具栏项
        // 在 macOS 的分栏视图里本来就落在标题栏最右端。
        .toolbar {
            ToolbarItemGroup {
                searchCount
                scopeMenu
                filterMenu
            }
        }
        // 搜索框摆在窗口右上角，交给系统的 searchable：工具栏里放不得自己包的
        // NSView——SwiftUI 重建工具栏宿主视图时会 endEditing，而结束编辑又会引起
        // 一次布局，转回来再重建一次，主线程就此转死（回车最容易点着这个循环）。
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索邮件")
        // 选择/显示方式/过滤器变化：纯本地重算，不联网
        .onChange(of: viewKey, initial: true) { _, _ in
            // 协调器的引用在这里就绪，不依赖列表有没有内容（空邮箱时 list 不会被求值）
            rows.model = model
            rows.appState = appState
            model.bind(to: mailStore)
            model.configure(accounts: searchAccounts, labelID: appState.selection?.labelID ?? "",
                            conversation: conversationView, filter: readFilter,
                            search: debouncedSearch, searchScope: searchScope)
            // 垃圾邮件/废纸篓不在账户级拉取的返回范围内，第一次点进去才去要
            if let selection = appState.selection {
                Task { await ensureSpecialMailbox(selection) }
            }
        }
        .task(id: appState.activeAccounts.map(\.id)) {
            let ids = appState.activeAccounts.map(\.id)
            // 先恢复磁盘上的池子，不联网
            await mailStore.restore(accounts: ids)
            if didColdStart {
                // 切分组带进来的新账号：它还没有自己的「冷启动」，补一次
                for id in ids where mailStore.isEmpty(account: id) {
                    await MailRefresh.account(id, labels: labelStore, mail: mailStore)
                }
            } else {
                didColdStart = true
                await MailRefresh.accounts(ids, labels: labelStore, mail: mailStore)
            }
            isFirstLoad = false
        }
        // 侧栏账号行上的刷新按钮
        .onChange(of: appState.syncRequest) { _, request in
            guard let request else { return }
            Task {
                if let account = request.accountID {
                    await MailRefresh.account(account, labels: labelStore, mail: mailStore)
                } else {
                    await MailRefresh.accounts(appState.activeAccounts.map(\.id),
                                               labels: labelStore, mail: mailStore)
                }
            }
        }
        // 输入防抖：真正参与重算的是 debouncedSearch
        .task(id: searchText) {
            if searchText.isEmpty {
                debouncedSearch = ""
                return
            }
            try? await Task.sleep(for: Self.searchDebounce)
            guard !Task.isCancelled else { return }
            debouncedSearch = searchText
        }
        // 「编辑 → 搜索邮件」（⌘F）
        .onChange(of: appState.searchFocusRequest) { _, _ in
            SearchFieldFocus.begin()
        }
        // 「所有账号」要搜到分组之外的账号，它们的池子未必恢复过（列表那条 task
        // 只管当前分组）。恢复是纯读盘，且对已经在内存里的账号是空操作。
        .task(id: searchScopeRaw) {
            guard case .all = searchScope else { return }
            await mailStore.restore(accounts: appState.accounts.map(\.id))
        }
        // 换邮箱就把搜索词丢掉：搜索是一次性的动作，而点侧栏是「换个地方看」。
        // 留着上一次的词，新邮箱看起来会是空的，而空的原因藏在上面那个小框里。
        .onChange(of: appState.selection) { _, _ in
            guard !searchText.isEmpty else { return }
            clearSearch()
        }
        .onChange(of: conversationView) { _, _ in
            // 两种模式的行 id 语义不同（threadId ↔ messageId），旧选择必须清空
            appState.selectedThreads = []
            appState.selectedInfos = []
        }
        // 详情栏点「删除」：由列表执行，顺带自动选中下一封
        .onChange(of: appState.trashRequest) { _, request in
            guard let request else { return }
            rows.performTrash([SelectedThread(accountID: request.account, threadID: request.id)])
        }
        // 双击某一行：开一扇独立窗口。同一封邮件再双击时，SwiftUI 认窗口值，
        // 会把已经开着的那扇拿到前台，而不是叠一扇新的。
        .onChange(of: appState.detachRequest) { _, request in
            guard let request else { return }
            openWindow(id: MessageWindow.id,
                       value: SelectedThread(accountID: request.account, threadID: request.id))
        }
        .onChange(of: appState.selectedThreads) { _, sel in
            // 同步选中项摘要（供右栏多选叠加卡片），保持列表顺序。
            // 必须推迟一拍再写回：这里仍处在 NSTableView 的选择回调里，
            // 同步改 appState 会让 List 在 delegate 内部重建（AppKit 会报 reentrant 警告），
            // 表现为点一下邮件整个界面闪一下。
            let infos = model.summaries
                .filter { sel.contains($0.key) }
                .map { SelectedThreadInfo(accountID: $0.accountID, threadID: $0.id,
                                          from: $0.from, subject: $0.subject, date: $0.date) }
            Task { @MainActor in appState.selectedInfos = infos }
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if appState.selection == nil {
            ContentUnavailableView("未选择邮箱", systemImage: "tray")
        } else if model.summaries.isEmpty && isFirstLoad {
            ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.summaries.isEmpty && !debouncedSearch.isEmpty {
            ContentUnavailableView {
                Label("没有找到匹配的邮件", systemImage: "magnifyingglass")
            } description: {
                Text(searchEmptyHint)
            }
        } else if model.summaries.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: readFilter == .all ? "tray" : "line.3.horizontal.decrease.circle")
            } description: {
                Text(emptyHint)
            }
        } else {
            list
        }
    }

    // MARK: - 搜索框（窗口右上角，纯本地，不发任何请求）

    /// 搜索范围。做成下拉而不是摊开的范围条：账号一多，摊开就把中栏顶出去了。
    ///
    /// 只在搜着的时候出现——不搜的时候它没有意义，白占工具栏。
    @ViewBuilder
    private var scopeMenu: some View {
        if !debouncedSearch.isEmpty {
            Menu {
                Picker("搜索范围", selection: searchScopeBinding) {
                    Text("当前邮箱").tag(SearchScope.mailbox)
                    Divider()
                    ForEach(scopeAccounts) { account in
                        Text(account.displayName).tag(SearchScope.account(account.id))
                    }
                    // 只有一个账号时，「所有账号」和它自己是同一件事，不必多摆一档
                    if appState.accounts.count > 1 {
                        Divider()
                        Text("所有账号").tag(SearchScope.all)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(scopeTitle)
                    .lineLimit(1)
                    // 账号那档是邮箱地址，掐中间：两头都是认人的地方
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 150)
            .help("搜索范围：\(scopeTitle)")
        }
    }

    /// 当前范围叫什么（下拉按钮上显示的那行字）。
    private var scopeTitle: String {
        switch searchScope {
        case .mailbox: return "当前邮箱"
        case .account(let id): return appState.accounts.first { $0.id == id }?.displayName ?? id
        case .all: return "所有账号"
        }
    }

    /// 搜到几条。摆在搜索框左边，只在搜着的时候出现。
    @ViewBuilder
    private var searchCount: some View {
        if !debouncedSearch.isEmpty {
            Text(model.summaries.isEmpty ? "没有结果" : "\(model.summaries.count) 个结果")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func clearSearch() {
        searchText = ""
        debouncedSearch = ""
    }

    /// 搜不到时把话说清楚：搜索范围本来就只有本地那一段。
    private var searchEmptyHint: String {
        var lines = ["搜的是本地已同步的邮件，只看发件人、主题和摘要——正文不参与。",
                     "可以用 from: subject: is:unread is:starred has:attachment 限定，"
                     + "多个条件是「且」，带空格的短语加引号。"]
        switch searchScope {
        case .mailbox:
            lines.append("把范围换成某个账号，可以搜遍它的全部邮件，不再受当前邮箱限制。")
        case .account(let id):
            let name = appState.accounts.first { $0.id == id }?.displayName ?? id
            if appState.accounts.count > 1 {
                lines.append("这一档只搜「\(name)」，换成「所有账号」可以搜得更宽。")
            }
        case .all:
            break
        }
        if let oldest = oldestBackfillDate {
            lines.append("本地有 \(DateText.fullDate(oldest)) 至今的邮件，更早的要在「设置 → 同步」里调大回溯范围。")
        }
        return lines.joined(separator: "\n")
    }

    private var list: some View {
        // 每次布局刷新协调器持有的引用（都是长期存活的对象，不会引起额外刷新）
        rows.model = model
        rows.appState = appState
        rows.updateLabelMap(labelMap)

        let selection = Binding<Set<SelectedThread>>(
            get: { appState.selectedThreads },
            set: { new in
                guard new != appState.selectedThreads else { return }
                appState.selectedThreads = new
            }
        )
        return List(selection: selection) {
            ForEach(rowItems) { item in
                row(item.summary)
            }
            backfillFooter
        }
        .listStyle(.inset)
        // 双击某行 → 独立窗口。装在列表上而不是行上，用的是表格自己的双击动作，
        // 单击选中因此毫发无伤，详见 ThreadListDoubleClick。
        .background(ThreadListDoubleClick())
        // 浮动批量条：用 overlay 不占布局空间，避免出现/消失时列表位移
        .overlay(alignment: .bottom) { batchBar }
        // 按删除键：删除所有选中的会话
        .onDeleteCommand {
            if !appState.selectedThreads.isEmpty {
                rows.performTrash(Array(appState.selectedThreads))
            }
        }
        // 按 ESC：取消选中
        .onExitCommand {
            if !appState.selectedThreads.isEmpty { appState.selectedThreads = [] }
        }
    }

    // MARK: - 单行（可拖入标签）

    /// 列表行的身份：会话 key 再加上「这行有没有标签 chip」。
    ///
    /// macOS 的 List 底下是 NSTableView，行高按行身份缓存：身份不变时只换内容，
    /// 高度沿用旧值 —— 给一封原本没标签的邮件打上标签，chip 那一行就会被行的下边缘裁掉。
    /// 身份只在「有 chip / 没 chip」之间翻转，正对应唯一一次真实的高度变化；
    /// 已读、旗标这些不改高度的变化不参与，免得白白重建整行。
    private struct RowItem: Identifiable {
        let summary: ThreadSummary
        let hasChips: Bool
        var id: String { "\(summary.accountID)\t\(summary.id)\t\(hasChips ? 1 : 0)" }
    }

    private var rowItems: [RowItem] {
        let map = rows.labelMap
        return model.summaries.map { summary in
            RowItem(summary: summary,
                    hasChips: summary.labelIds.contains { map["\(summary.accountID)\t\($0)"] != nil })
        }
    }

    private func row(_ summary: ThreadSummary) -> some View {
        // 传给行的必须全是可比较的值加一个稳定的引用；一旦混进闭包，
        // SwiftUI 每次改选中都会重建整行并重新注册拖放，触发 NSTableView 重入。
        ThreadListRow(
            summary: summary,
            labelMap: rows.labelMap,
            accountBadge: badge(for: summary),
            avatarReloadToken: appState.avatarReloadToken,
            affinity: rows.labelDropAffinity(summary),
            isDropTarget: rows.dropTargetKey == summary.key,
            placement: rows.placement(summary)
        )
        // 登记这一行的位置：多选叠加卡片要从这儿起飞、飞回这儿来
        .background(ThreadRowFrameReporter(key: summary.key))
        .tag(summary.key)
        .listRowBackground(dropRowBackground(summary))
    }

    /// 可放置的行给浅色底，鼠标悬停其上时加深；非拖拽态返回 nil 以保留系统的选中高亮。
    private func dropRowBackground(_ summary: ThreadSummary) -> Color? {
        guard rows.labelDropAffinity(summary) == .enabled else { return nil }
        return rows.dropTargetKey == summary.key
            ? Color.accentColor.opacity(0.32)
            : Color.accentColor.opacity(0.15)
    }

    // MARK: - 过滤器（主按钮切换未读/全部，右侧箭头展开三档）

    private var filterMenu: some View {
        Menu {
            Picker("过滤", selection: $readFilterRaw) {
                ForEach(ReadFilter.allCases) { f in
                    Label(f.title, systemImage: f.systemImage).tag(f.rawValue)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: readFilter == .all
                  ? "line.3.horizontal.decrease.circle"
                  : "line.3.horizontal.decrease.circle.fill")
        } primaryAction: {
            // 点主按钮：在「仅未读」和「全部」之间来回切
            readFilterRaw = (readFilter == .unread ? ReadFilter.all : .unread).rawValue
        }
        .menuIndicator(.visible)
        .help(readFilter == .all ? "只看未读" : "过滤：\(readFilter.title)")
        .disabled(appState.selection == nil)
    }

    private var emptyTitle: String {
        switch readFilter {
        case .all: return conversationView ? "没有会话" : "没有邮件"
        case .unread: return "没有未读邮件"
        case .read: return "没有已读邮件"
        }
    }

    /// 空列表时说明原因：回溯范围之外的邮件本来就不在本地。
    private var emptyHint: String {
        guard readFilter == .all else { return "换个过滤条件看看" }
        guard let oldest = oldestBackfillDate else { return "这个邮箱在已同步的邮件里一封都没有" }
        return "已同步 \(DateText.fullDate(oldest)) 至今的邮件，这个邮箱在这个范围里没有内容。要看更早的，在「设置 → 同步」里调大回溯范围。"
    }

    /// 列表底部标出回溯到哪儿了——到底就是到底，不再往下自动加载。
    @ViewBuilder
    private var backfillFooter: some View {
        if !model.summaries.isEmpty, let oldest = oldestBackfillDate {
            HStack {
                Spacer()
                Text("已回溯至 \(DateText.fullDate(oldest))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.vertical, 6)
            .listRowSeparator(.hidden)
            .selectionDisabled()
        }
    }

    /// 当前视图涉及的账号里，回溯得最浅的那个（多账号聚合时，短板决定了能看到多早）。
    private var oldestBackfillDate: Date? {
        searchAccounts.compactMap { mailStore.oldestDate(account: $0) }.max()
    }

    /// 垃圾邮件 / 废纸篓：Gmail 的列表接口默认不返回，第一次点进去时单独拉一次。
    private func ensureSpecialMailbox(_ selection: MailboxSelection) async {
        guard MailboxQuery.needsExplicitFetch(labelID: selection.labelID) else { return }
        for account in selectionAccounts {
            await mailStore.ensureMailbox(account: account, labelID: selection.labelID)
        }
    }

    // MARK: - 批量操作条（贴列表顶部）

    @ViewBuilder
    private var batchBar: some View {
        if appState.selectedThreads.count >= 2 {
            let sel = Array(appState.selectedThreads)
            let placements = selectionPlacements
            HStack(spacing: 14) {
                Text("已选 \(sel.count) 封").font(.callout).foregroundStyle(.secondary)
                if placements.contains(where: \.canTrash) {
                    Button { rows.performTrash(sel) } label: { Image(systemName: "trash") }.help("删除所选")
                }
                if placements.contains(where: \.canArchive) {
                    Button { rows.performArchive(sel) } label: { Image(systemName: "archivebox") }.help("归档所选")
                }
                if placements.contains(where: \.canMoveToInbox) {
                    Button { rows.performMoveToInbox(sel) } label: {
                        Image(systemName: "tray.and.arrow.down")
                    }.help("把所选移回收件箱")
                }
                Button { rows.markRead(sel) } label: {
                    Image(systemName: "envelope.open")
                }.help("标记所选为已读")
                Button { rows.star(sel) } label: {
                    Image(systemName: "flag")
                }.help("给所选加旗标")
                Divider().frame(height: 14)
                Button("取消") { appState.selectedThreads = [] }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 行操作

    /// 当前选中的这几封分别处在哪一态。
    ///
    /// 多选可以横跨三态（尤其在「所有邮件」里），所以批量条按并集摆按钮：
    /// 有一封还能删就摆删除，有一封还能归档就摆归档——按下去只作用于对得上的那部分，
    /// 筛选在 `ThreadRowCoordinator` 里做。
    private var selectionPlacements: Set<MailPlacement> {
        let selected = appState.selectedThreads
        return Set(model.summaries.filter { selected.contains($0.key) }
            .map { MailPlacement(labels: $0.labelIds) })
    }

    /// 列表里不止一个账号时，给每行一个来源账号徽标。
    ///
    /// 判断依据是「这次实际算了哪几个账号」而不是「是不是聚合视图」：
    /// 在某个账号的收件箱里把搜索范围放到「所有账号」，结果里就会混进别人的邮件，
    /// 那时候不标出来，看到的人只会以为这封信也是当前账号的。
    private func badge(for summary: ThreadSummary) -> Account? {
        guard searchAccounts.count > 1 else { return nil }
        return appState.accounts.first { $0.id == summary.accountID }
    }

    /// 重算列表的依据：邮箱选择 + 参与的账号 + 显示方式 + 过滤 + 搜索。全是本地计算。
    private struct ViewKey: Hashable {
        let selection: MailboxSelection?
        let accounts: [String]
        let conversation: Bool
        let filter: String
        let search: String
        let scope: String
    }

    private var viewKey: ViewKey {
        ViewKey(selection: appState.selection, accounts: searchAccounts,
                conversation: conversationView, filter: readFilterRaw,
                search: debouncedSearch, scope: searchScopeRaw)
    }
}

/// 列表行的外壳。
///
/// 字段刻意全部是可比较的值 + 一个长期存活的协调器引用，没有任何闭包：
/// 这样点击换选中时，SwiftUI 比较下来发现行没变就整行跳过，不会重建行内容、
/// 重新注册拖放 —— 那件事若发生在 NSTableView 的选择回调里，AppKit 会报 reentrant 警告，
/// 用户看到的就是「点一封邮件整个界面刷新一下」。
private struct ThreadListRow: View {
    let summary: ThreadSummary
    let labelMap: [String: GmailLabel]
    let accountBadge: Account?
    let avatarReloadToken: Int
    let affinity: DropAffinity
    let isDropTarget: Bool
    /// 这一行在收件箱、归档，还是废纸篓——滑动和右键里摆哪几个动作全看它。
    let placement: MailPlacement

    /// 静态访问，不作为字段存起来：字段里一旦有引用，行上的 modifier 就无法被判定为「没变」。
    private var rows: ThreadRowCoordinator { .shared }

    @ViewBuilder
    var body: some View {
        let base = ThreadRow(summary: summary, labelMap: labelMap,
                  accountBadge: accountBadge, avatarReloadToken: avatarReloadToken)
            .contextMenu { menu }
            // 右滑：标记已读/未读、旗标；左滑：归档、删除（纯图标）
            .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipe }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingSwipe }
            .opacity(affinity.dimmed ? 0.35 : 1)
            .animation(.easeOut(duration: 0.15), value: affinity.dimmed)

        // 放置区只在真的拖着标签时才挂。onDrop 的闭包无法被 SwiftUI 判定为「没变」，
        // 常挂着会让每次改选中都重新注册一次放置区 —— 那正是 NSTableView 重入的来源。
        // 平时不挂既省掉重入，也让不可放置的行直接显示禁止光标。
        if affinity == .enabled {
            base.onDrop(of: [.mgmailLabel], isTargeted: Binding(
                get: { isDropTarget },
                set: { ThreadRowCoordinator.shared.setDropTarget($0, key: summary.key) }
            )) { ThreadRowCoordinator.shared.acceptLabelDrop($0, on: summary) }
        } else {
            base
        }
    }

    @ViewBuilder
    private var leadingSwipe: some View {
        Button { rows.toggleUnread(summary) } label: {
            Image(systemName: summary.isUnread ? "envelope.open" : "envelope")
        }.tint(.blue)
        Button { rows.toggleStar(summary) } label: {
            Image(systemName: summary.isStarred ? "flag.slash" : "flag")
        }.tint(.orange)
    }

    @ViewBuilder
    private var trailingSwipe: some View {
        if placement.canTrash {
            Button(role: .destructive) { rows.trash(summary) } label: {
                Image(systemName: "trash")
            }
        }
        Button {
            if placement.canArchive { rows.archive(summary) } else { rows.moveToInbox(summary) }
        } label: {
            Image(systemName: placement.moveIcon)
        }.tint(.blue)
    }

    @ViewBuilder
    private var menu: some View {
        let n = rows.targets(summary).count
        let suffix = n > 1 ? "（\(n) 封）" : ""
        // 双击是这个功能的主入口，但双击本身看不见，菜单里得留个能被发现的说法
        Button("在新窗口中打开") { rows.openInWindow(summary.key) }
        Divider()
        Button((summary.isUnread ? "标记为已读" : "标记为未读") + suffix) { rows.toggleUnread(summary) }
        Button((summary.isStarred ? "取消旗标" : "旗标") + suffix) { rows.toggleStar(summary) }
        Button(placement.moveTitle + suffix) {
            if placement.canArchive { rows.archive(summary) } else { rows.moveToInbox(summary) }
        }
        labelSubmenu(suffix)
        if placement.canTrash {
            Divider()
            Button("删除" + suffix, role: .destructive) { rows.trash(summary) }
        }
    }

    /// 右键里的标签子菜单：勾选即加、取消即去，一次一个请求。
    @ViewBuilder
    private func labelSubmenu(_ suffix: String) -> some View {
        let prefix = "\(summary.accountID)\t"
        let mine = labelMap.filter { $0.key.hasPrefix(prefix) }.map(\.value)
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        if !mine.isEmpty {
            Divider()
            Menu("标签" + suffix) {
                ForEach(mine) { label in
                    let on = summary.labelIds.contains(label.id)
                    Button {
                        rows.toggleLabel(label.id, on: summary, currentlyOn: on)
                    } label: {
                        Label(label.name, systemImage: on ? "checkmark.circle.fill" : "circle")
                    }
                }
            }
        }
    }
}

/// 会话列表的单行（仿 Mail：发件人加粗、主题、摘要、时间、未读点）。
struct ThreadRow: View {
    let summary: ThreadSummary
    var labelMap: [String: GmailLabel] = [:]
    /// 聚合视图里标识来源账号（单账号视图为 nil，不显示）。
    var accountBadge: Account?
    var avatarReloadToken: Int = 0

    /// 该会话对应的用户标签（按名称排序，最多显示若干个）。
    private var labels: [GmailLabel] {
        summary.labelIds.compactMap { labelMap["\(summary.accountID)\t\($0)"] }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(summary.isUnread ? Color.accentColor : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(summary.from)
                        .fontWeight(summary.isUnread ? .bold : .regular)
                        .lineLimit(1)
                    if summary.messageCount > 1 {
                        Text("\(summary.messageCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    Spacer()
                    Text(DateText.listRow(summary.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let account = accountBadge {
                        AccountAvatar(account: account, size: 12, reloadToken: avatarReloadToken)
                            .help(account.email)
                    }
                }
                HStack(spacing: 4) {
                    if summary.isStarred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(summary.subject)
                        .fontWeight(summary.isUnread ? .semibold : .regular)
                        .lineLimit(1)
                    if summary.hasAttachment {
                        Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(summary.snippet)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if !labels.isEmpty {
                    labelChips
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// 标签 chip 行：最多显示 3 个，超出用 +N。
    private var labelChips: some View {
        let maxShown = 3
        let shown = labels.prefix(maxShown)
        let extra = labels.count - shown.count
        return HStack(spacing: 4) {
            ForEach(Array(shown)) { label in
                Text(label.name.split(separator: "/").last.map(String.init) ?? label.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill((label.uiColor ?? .secondary).opacity(0.9)))
                    .foregroundStyle(label.uiTextColor ?? .white)
            }
            if extra > 0 {
                Text("+\(extra)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 1)
    }

}
