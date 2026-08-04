import SwiftUI

/// 中栏：会话列表。
struct ThreadListView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var labelStore: LabelStore
    @StateObject private var model = ThreadListModel()

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
                ContentUnavailableView("没有邮件", systemImage: "tray")
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
        }
        .task(id: appState.selection) {
            // 首次加载或选择变化时重新加载
            await reload()
        }
        .onChange(of: appState.lastThreadChange) { _, change in
            guard let change else { return }
            Task { await model.refreshRow(account: change.account, id: change.id) }
        }
        .onChange(of: appState.selectedThreads) { _, sel in
            // 同步选中项摘要（供右栏多选叠加卡片），保持列表顺序
            appState.selectedInfos = model.summaries
                .filter { sel.contains($0.key) }
                .map { SelectedThreadInfo(accountID: $0.accountID, threadID: $0.id,
                                          from: $0.from, subject: $0.subject, date: $0.date) }
        }
    }

    private var list: some View {
        List(selection: $appState.selectedThreads) {
            ForEach(model.summaries) { summary in
                ThreadRow(summary: summary, labelMap: labelMap, accountBadge: badge(for: summary),
                          avatarReloadToken: appState.avatarReloadToken)
                    .tag(SelectedThread(accountID: summary.accountID, threadID: summary.id))
                    .contextMenu { rowMenu(summary) }
                    // 右滑：标记已读/未读、旗标；左滑：归档、删除（纯图标）
                    .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingSwipe(summary) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingSwipe(summary) }
                    .onAppear {
                        if summary.id == model.summaries.last?.id {
                            Task { await model.loadMore() }
                        }
                    }
            }
            if model.isLoading && !model.summaries.isEmpty {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            }
        }
        .listStyle(.inset)
        // 浮动批量条：用 overlay 不占布局空间，避免出现/消失时列表位移
        .overlay(alignment: .bottom) { batchBar }
        // 按删除键：删除所有选中的会话
        .onDeleteCommand {
            if !appState.selectedThreads.isEmpty {
                performTrash(Array(appState.selectedThreads))
            }
        }
        // 按 ESC：取消选中
        .onExitCommand {
            if !appState.selectedThreads.isEmpty { appState.selectedThreads = [] }
        }
    }

    // MARK: - 批量操作条（贴列表顶部）

    @ViewBuilder
    private var batchBar: some View {
        if appState.selectedThreads.count >= 2 {
            let sel = Array(appState.selectedThreads)
            HStack(spacing: 14) {
                Text("已选 \(sel.count) 封").font(.callout).foregroundStyle(.secondary)
                Button { performTrash(sel) } label: { Image(systemName: "trash") }.help("删除所选")
                if isArchivable {
                    Button { performArchive(sel) } label: { Image(systemName: "archivebox") }.help("归档所选")
                }
                Button { Task { await model.mutateMany(sel, remove: ["UNREAD"]) } } label: {
                    Image(systemName: "envelope.open")
                }.help("标记所选为已读")
                Button { Task { await model.mutateMany(sel, add: ["STARRED"]) } } label: {
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

    // MARK: - 滑动动作（纯图标）

    @ViewBuilder
    private func leadingSwipe(_ s: ThreadSummary) -> some View {
        Button { toggleUnread(s) } label: {
            Image(systemName: s.isUnread ? "envelope.open" : "envelope")
        }.tint(.blue)
        Button { toggleStar(s) } label: {
            Image(systemName: s.isStarred ? "flag.slash" : "flag")
        }.tint(.orange)
    }

    @ViewBuilder
    private func trailingSwipe(_ s: ThreadSummary) -> some View {
        Button(role: .destructive) { trash(s) } label: {
            Image(systemName: "trash")
        }
        if isArchivable {
            Button { archive(s) } label: {
                Image(systemName: "archivebox")
            }.tint(.blue)
        }
    }

    @ViewBuilder
    private func rowMenu(_ summary: ThreadSummary) -> some View {
        let n = targets(summary).count
        let suffix = n > 1 ? "（\(n) 封）" : ""
        Button((summary.isUnread ? "标记为已读" : "标记为未读") + suffix) { toggleUnread(summary) }
        Button((summary.isStarred ? "取消旗标" : "旗标") + suffix) { toggleStar(summary) }
        if isArchivable {
            Button("归档" + suffix) { archive(summary) }
        }
        Divider()
        Button("删除" + suffix, role: .destructive) { trash(summary) }
    }

    // MARK: - 行操作

    /// 当前邮箱是否支持“归档”（仅收件箱有意义）。
    private var isArchivable: Bool { appState.selection?.labelID == "INBOX" }

    /// 行上手势/菜单的作用对象：若该行属于当前多选，则作用于整组，否则仅该行。
    private func targets(_ summary: ThreadSummary) -> [SelectedThread] {
        if appState.selectedThreads.count > 1, appState.selectedThreads.contains(summary.key) {
            return Array(appState.selectedThreads)
        }
        return [summary.key]
    }

    private func toggleStar(_ summary: ThreadSummary) {
        Task { await model.mutateMany(targets(summary), add: summary.isStarred ? [] : ["STARRED"],
                                      remove: summary.isStarred ? ["STARRED"] : []) }
    }

    private func toggleUnread(_ summary: ThreadSummary) {
        Task { await model.mutateMany(targets(summary), add: summary.isUnread ? [] : ["UNREAD"],
                                      remove: summary.isUnread ? ["UNREAD"] : []) }
    }

    private func archive(_ summary: ThreadSummary) { performArchive(targets(summary)) }
    private func trash(_ summary: ThreadSummary) { performTrash(targets(summary)) }

    // MARK: - 批量执行（含删除/归档后自动选中下一封）

    private func performTrash(_ keys: [SelectedThread]) {
        let advance = advanceSelectionIfNeeded(removing: keys)
        Task { await model.trashMany(keys) }
        applyAdvance(advance, removed: keys)
    }

    private func performArchive(_ keys: [SelectedThread]) {
        let advance = advanceSelectionIfNeeded(removing: keys)
        Task { await model.mutateMany(keys, remove: ["INBOX"]) }
        applyAdvance(advance, removed: keys)
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
            let keySet = Set(keys)
            appState.selectedThreads.subtract(keySet)
        case .some(let next):
            appState.selectedThreads = next.map { [$0] } ?? []
        }
    }

    /// 聚合视图（accountID 为 nil）时给每行一个来源账号徽标。
    private func badge(for summary: ThreadSummary) -> Account? {
        guard appState.selection?.accountID == nil else { return nil }
        return appState.accounts.first { $0.id == summary.accountID }
    }

    private func reload() async {
        guard let sel = appState.selection else { return }
        await model.load(accounts: selectionAccounts, labelID: sel.labelID)
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
