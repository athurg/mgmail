import SwiftUI

/// 左栏：账户与邮箱/标签。
///
/// 结构（仿 Apple Mail）：
/// - 顶部「智能邮箱」：跨账号聚合，只放日常真会一起看的收件箱与星标。
/// - 账号分组：每个账号一个分组，内含该账号的全部标签——固定邮箱、
///   收件箱分类（CATEGORY_*）、自定义标签树。
struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var mailStore: MailStore
    /// 各账号是否有网络请求在飞，用于在账号条目上显示忙碌指示。
    @ObservedObject private var activity = NetworkActivity.shared
    @State private var expandedLabels: Set<String> = LabelExpansionStore.load()
    /// 自定义标签分组里被折叠的账户（默认展开，记录“已折叠”）。
    @State private var collapsedAccounts: Set<String> = LabelExpansionStore.loadCollapsed()

    var body: some View {
        List(selection: Binding(
            get: { appState.selection },
            set: { appState.selection = $0 }
        )) {
            if appState.accounts.isEmpty {
                emptyState
            } else if appState.activeAccounts.isEmpty {
                emptyProfileState
            } else {
                fixedLabelsSection
                customLabelsSections
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !appState.accounts.isEmpty {
                ProfileSwitcher()
            }
        }
        .sheet(item: $appState.labelEditTarget) { target in
            LabelEditSheet(target: target)
                .environmentObject(labelStore)
        }
        .task(id: appState.activeAccounts.map(\.id)) {
            // 只补齐本地还没有的账号标签；已有缓存就直接用，要最新的走账号行上的刷新按钮
            await withTaskGroup(of: Void.self) { group in
                for account in appState.activeAccounts {
                    group.addTask { await labelStore.loadIfNeeded(for: account.id) }
                }
            }
        }
    }

    // MARK: - 智能邮箱（跨账号聚合）

    @ViewBuilder
    private var fixedLabelsSection: some View {
        Section("智能邮箱") {
            // 汇总当前分组的所有账号。只放收件箱和星标——已发送、草稿、垃圾邮件、
            // 废纸篓都是「针对某个账号」才有意义的，去下面各账号自己的分组里看。
            ForEach(StandardMailbox.smart) { box in
                Label(box.name, systemImage: box.systemImage)
                    .tag(MailboxSelection(accountID: nil, labelID: box.id, labelName: box.name))
            }
        }
    }

    // MARK: - 账号分组（账户 → 该账号的全部标签）

    @ViewBuilder
    private var customLabelsSections: some View {
        ForEach(appState.activeAccounts) { account in
            let tree = LabelTree.build(labelStore.userLabels(for: account.id))
            let categories = labelStore.categories(for: account.id)
            // 可折叠：点账号名（分组头）隐藏/展开该账号的标签列表。默认展开。
            Section(isExpanded: accountBinding(account.id)) {
                // 该账号自己的固定邮箱：顶部是聚合视图，这里才能单看一个账号
                ForEach(StandardMailbox.all) { box in
                    Label(box.name, systemImage: box.systemImage)
                        .tag(MailboxSelection(accountID: account.id, labelID: box.id,
                                              labelName: "\(account.displayName) · \(box.name)"))
                }
                // 收件箱分类（主要/社交/推广…）：条目多且不常用，收进一个默认折叠的组
                if !categories.isEmpty {
                    DisclosureGroup(isExpanded: groupBinding("cat:\(account.id)")) {
                        ForEach(categories) { category in
                            Label(category.name, systemImage: category.systemImage)
                                .tag(MailboxSelection(accountID: account.id, labelID: category.id,
                                                      labelName: "\(account.displayName) · \(category.name)"))
                        }
                    } label: {
                        Label("分类", systemImage: "square.grid.2x2")
                    }
                }
                ForEach(tree) { node in
                    LabelNodeView(node: node, accountID: account.id, expanded: $expandedLabels)
                }
            } header: {
                accountHeader(account)
            }
        }
    }

    /// 自定义标签分组的展开绑定（默认展开，记录“已折叠”）。
    private func accountBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !collapsedAccounts.contains(id) },
            set: { isOpen in
                if isOpen { collapsedAccounts.remove(id) } else { collapsedAccounts.insert(id) }
                LabelExpansionStore.saveCollapsed(collapsedAccounts)
            }
        )
    }

    // MARK: - 其它

    private var emptyState: some View {
        ContentUnavailableView {
            Label("暂无账户", systemImage: "person.crop.circle.badge.plus")
        } description: {
            if appState.hasOAuthConfig {
                Text("从菜单栏「账号 → 账号与分组…」添加你的 Gmail")
            } else {
                Text("先完成 OAuth 配置，再添加账户")
            }
        }
    }

    /// 当前分组里一个账号都没有时的占位。
    private var emptyProfileState: some View {
        ContentUnavailableView {
            Label("该分组暂无账号", systemImage: "person.2.slash")
        } description: {
            Text("右键分组标签选「管理分组…」把账号加进来，或再点一次该标签回到全部账号")
        }
    }

    private func accountHeader(_ account: Account) -> some View {
        HStack(spacing: 6) {
            AccountAvatar(account: account, size: 16, reloadToken: appState.avatarReloadToken)
            VStack(alignment: .leading, spacing: 0) {
                Text(account.displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !account.note.isEmpty {
                    Text(account.note)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                // 本地邮件回溯到哪儿了。淡淡一行，解释了「为什么有些邮箱是空的」
                if let oldest = mailStore.oldestDate(account: account.id) {
                    Text("邮件自 \(Self.backfillText(oldest))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            // 该账号有请求在飞时转圈；空闲时同一个位置放刷新按钮，
            // 两者尺寸一致，切换时分组头不会跟着跳。
            if activity.busyAccounts.contains(account.id) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.6)
                    .frame(width: 12, height: 12)
                    .transition(.opacity)
            } else {
                Button { refresh(account) } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .frame(width: 12, height: 12)
                }
                .buttonStyle(.borderless)
                .help("刷新该账号（同步邮件与标签）")
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: activity.busyAccounts.contains(account.id))
        .help(account.email)
        .contextMenu {
            Button("新建标签…") {
                appState.labelEditTarget = LabelEditTarget(accountID: account.id, label: nil)
            }
            Divider()
            SettingsLink { Text("账号与分组…") }
            Button("移除账户", role: .destructive) {
                mailStore.drop(account: account.id)
                appState.removeAccount(account)
            }
        }
    }

    /// 手动刷新一个账号：标签拉新，然后按位点同步邮件变化。
    private func refresh(_ account: Account) {
        Task { await MailRefresh.account(account.id, labels: labelStore, mail: mailStore) }
    }

    private static func backfillText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? "M月d日" : "yyyy年M月"
        return f.string(from: date)
    }

    /// 「分类」等次级分组的展开绑定（默认折叠，记录“已展开”，与标签树同一套持久化）。
    private func groupBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedLabels.contains(id) },
            set: { isOpen in
                if isOpen { expandedLabels.insert(id) } else { expandedLabels.remove(id) }
                LabelExpansionStore.save(expandedLabels)
            }
        )
    }
}

/// 递归渲染一个标签节点：有子节点时用可折叠的 DisclosureGroup。
private struct LabelNodeView: View {
    let node: LabelNode
    let accountID: String
    @Binding var expanded: Set<String>
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if node.children.isEmpty {
            interactiveRow
        } else {
            DisclosureGroup(isExpanded: expandBinding) {
                ForEach(node.children) { child in
                    LabelNodeView(node: child, accountID: accountID, expanded: $expanded)
                }
            } label: {
                interactiveRow
            }
        }
    }

    /// 标签行 + 右键菜单 + 拖出自身（拖到邮件行上即给那封邮件打本标签）。
    @ViewBuilder
    private var interactiveRow: some View {
        let base = row.contextMenu { labelMenu }
        if let label = node.label {
            // 载荷表达式里只能出现值类型（见 DragMonitor 顶部说明）
            base.draggable(LabelDragPayload.beginning(
                account: accountID, labelID: label.id, labelName: label.name))
        } else {
            // 纯中间层没有真实标签，不能拖
            base
        }
    }

    @ViewBuilder
    private var labelMenu: some View {
        if let label = node.label {
            Button("编辑标签…") {
                appState.labelEditTarget = LabelEditTarget(accountID: accountID, label: label)
            }
        }
        Button("新建标签…") {
            appState.labelEditTarget = LabelEditTarget(accountID: accountID, label: nil)
        }
    }

    /// 单行标签（显示末段名 + 颜色标记），有真实标签时可被选中。
    @ViewBuilder
    private var row: some View {
        let label = node.label
        let content = Label {
            Text(node.title)
        } icon: {
            Image(systemName: label?.uiColor == nil ? "tag" : "tag.fill")
                .foregroundStyle(label?.uiColor ?? Color.secondary)
        }
        if let label {
            content.tag(MailboxSelection(accountID: accountID, labelID: label.id, labelName: label.name))
        } else {
            content.foregroundStyle(.secondary) // 纯中间层，不可选
        }
    }

    private var expandBinding: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.id) },
            set: { isOn in
                if isOn { expanded.insert(node.id) } else { expanded.remove(node.id) }
                LabelExpansionStore.save(expanded)
            }
        )
    }
}
