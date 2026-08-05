import SwiftUI

/// 中栏：会话列表。
struct ThreadListView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var labelStore: LabelStore
    @StateObject private var model = ThreadListModel()
    /// 全局设置：是否按会话显示邮件。默认关闭（每行一封独立邮件）。
    @AppStorage(SettingsKey.conversationView) private var conversationView = false
    /// 已读/未读过滤（右上角过滤器，记住上次选择）。
    @AppStorage(SettingsKey.readFilter) private var readFilterRaw = ReadFilter.all.rawValue
    /// 行的动作中枢（长期存活，保证行视图的字段稳定可比较，详见 ThreadRowCoordinator）。
    @ObservedObject private var rows = ThreadRowCoordinator.shared
    /// 拖拽状态：只有列表和侧栏订阅它，拖动时不会连累详情栏重绘。
    @ObservedObject private var drag = DragMonitor.shared

    private var readFilter: ReadFilter { ReadFilter(rawValue: readFilterRaw) ?? .all }

    /// 当前选择涉及的账号（聚合视图为当前分组内账号）。
    private var selectionAccounts: [String] {
        guard let sel = appState.selection else { return [] }
        if let acc = sel.accountID { return [acc] }
        return appState.activeAccounts.map(\.id)
    }

    /// 用户标签映射（"账号\t labelId" → 标签），聚合视图跨账号，供行内 chip 使用。
    private var labelMap: [String: GmailLabel] {
        var map: [String: GmailLabel] = [:]
        for account in selectionAccounts {
            for label in labelStore.userLabels(for: account) {
                map["\(account)\t\(label.id)"] = label
            }
        }
        return map
    }

    var body: some View {
        Group {
            if appState.selection == nil {
                ContentUnavailableView("未选择邮箱", systemImage: "tray")
            } else if let error = model.loadError, model.summaries.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("重试") { Task { await reload() } }
                }
            } else if model.summaries.isEmpty && model.isLoading {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.summaries.isEmpty {
                ContentUnavailableView(emptyTitle, systemImage: readFilter == .all ? "tray" : "line.3.horizontal.decrease.circle")
            } else {
                list
            }
        }
        .navigationTitle(appState.selection?.labelName ?? "收件箱")
        .toolbar {
            ToolbarItem {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await reload() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("刷新")
                    .disabled(appState.selection == nil)
                }
            }
            ToolbarItem { filterMenu }
        }
        .task(id: reloadKey) {
            // 首次加载、选择变化、或切换会话/单封显示方式时重新加载
            await reload()
        }
        .onChange(of: conversationView) { _, _ in
            // 两种模式的行 id 语义不同（threadId ↔ messageId），旧选择必须清空
            appState.selectedThreads = []
            appState.selectedInfos = []
        }
        .onChange(of: appState.lastThreadChange) { _, change in
            guard let change else { return }
            Task {
                for item in change.items {
                    await model.refreshRow(account: item.accountID, id: item.threadID)
                }
            }
        }
        // 详情栏点「删除」：由列表执行，顺带自动选中下一封
        .onChange(of: appState.trashRequest) { _, request in
            guard let request else { return }
            rows.performTrash([SelectedThread(accountID: request.account, threadID: request.id)])
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

    private var list: some View {
        // 每次布局刷新协调器持有的引用（都是长期存活的对象，不会引起额外刷新）
        rows.model = model
        rows.appState = appState
        rows.updateLabelMap(labelMap)
        DragMonitor.shared.appState = appState

        let selection = Binding<Set<SelectedThread>>(
            get: { appState.selectedThreads },
            set: { new in
                guard new != appState.selectedThreads else { return }
                appState.selectedThreads = new
            }
        )
        return List(selection: selection) {
            ForEach(model.summaries) { summary in
                row(summary)
            }
            if model.isLoading && !model.summaries.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            }
        }
        .listStyle(.inset)
        .onPreferenceChange(RowFramesKey.self) { frames in
            ThreadRowCoordinator.shared.rowFrames = frames
        }
        // 拖拽层：覆盖在列表之上但对点击透明，把「拖出邮件」从行里彻底移走。
        // 行上一旦挂拖拽 modifier，改选中就会在 NSTableView 的选择回调里重做注册（reentrant）。
        .overlay {
            ThreadDragLayer(
                rowAt: { ThreadRowCoordinator.shared.row(at: $0) },
                makePayload: { ThreadDragPayload.beginning($0) }
            )
        }
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

    // MARK: - 单行（含拖出邮件 / 拖入标签）

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
            isArchivable: isArchivable
        )
        .tag(summary.key)
        .listRowBackground(dropRowBackground(summary))
        // 上报位置给拖拽层做命中判断（纯几何，不注册任何 AppKit 东西）
        .background(GeometryReader { geo in
            // 用窗口全局坐标：拖拽层是 AppKit 视图，拿不到 SwiftUI 的具名坐标空间
            Color.clear.preference(key: RowFramesKey.self,
                                   value: [summary.key: geo.frame(in: .global)])
        })
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

    // MARK: - 批量操作条（贴列表顶部）

    @ViewBuilder
    private var batchBar: some View {
        if appState.selectedThreads.count >= 2 {
            let sel = Array(appState.selectedThreads)
            HStack(spacing: 14) {
                Text("已选 \(sel.count) 封").font(.callout).foregroundStyle(.secondary)
                Button { rows.performTrash(sel) } label: { Image(systemName: "trash") }.help("删除所选")
                if isArchivable {
                    Button { rows.performArchive(sel) } label: { Image(systemName: "archivebox") }.help("归档所选")
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

    /// 当前邮箱是否支持“归档”（仅收件箱有意义）。
    private var isArchivable: Bool { appState.selection?.labelID == "INBOX" }

    /// 聚合视图（accountID 为 nil）时给每行一个来源账号徽标。
    private func badge(for summary: ThreadSummary) -> Account? {
        guard appState.selection?.accountID == nil else { return nil }
        return appState.accounts.first { $0.id == summary.accountID }
    }

    /// 触发重新加载的依据：邮箱选择 + 显示方式 + 过滤。
    private struct ReloadKey: Hashable {
        let selection: MailboxSelection?
        let conversation: Bool
        let filter: String
    }

    private var reloadKey: ReloadKey {
        ReloadKey(selection: appState.selection, conversation: conversationView, filter: readFilterRaw)
    }

    private func reload() async {
        guard let sel = appState.selection else { return }
        await model.load(accounts: selectionAccounts, labelID: sel.labelID,
                         conversation: conversationView, filter: readFilter)
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
    let isArchivable: Bool

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
            .onAppear { rows.loadMoreIfNeeded(after: summary) }
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
        Button(role: .destructive) { rows.trash(summary) } label: {
            Image(systemName: "trash")
        }
        if isArchivable {
            Button { rows.archive(summary) } label: {
                Image(systemName: "archivebox")
            }.tint(.blue)
        }
    }

    @ViewBuilder
    private var menu: some View {
        let n = rows.targets(summary).count
        let suffix = n > 1 ? "（\(n) 封）" : ""
        Button((summary.isUnread ? "标记为已读" : "标记为未读") + suffix) { rows.toggleUnread(summary) }
        Button((summary.isStarred ? "取消旗标" : "旗标") + suffix) { rows.toggleStar(summary) }
        if isArchivable {
            Button("归档" + suffix) { rows.archive(summary) }
        }
        labelSubmenu(suffix)
        Divider()
        Button("删除" + suffix, role: .destructive) { rows.trash(summary) }
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
                    Text(Self.dateText(summary.date))
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

    static func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else if Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) {
            formatter.dateFormat = "M月d日"
        } else {
            formatter.dateFormat = "yyyy/M/d"
        }
        return formatter.string(from: date)
    }
}
