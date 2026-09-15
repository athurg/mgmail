import SwiftUI

/// 左栏：账户与邮箱/标签。
///
/// 结构（仿 Apple Mail 的内容，Telegram 的皮）：
/// - 顶部「智能邮箱」卡片：跨账号聚合，只放日常真会一起看的收件箱与星标。
/// - 每个账号一张卡片：账号头 + 该账号的全部标签——固定邮箱、收件箱分类（CATEGORY_*）、
///   自定义标签树。卡片是玻璃材质、悬浮在侧栏底色上，卡与卡之间留空，一眼分得清哪个账号管哪些邮箱。
///
/// 不用 `List`：List 的选中高亮、行底都是一行一块，拼不出一张连贯的悬浮卡片；
/// 这里用 ScrollView + 自己画的行，选中高亮也自己画。
struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var mailStore: MailStore
    /// 各账号是否有网络请求在飞，用于在账号条目上显示忙碌指示。
    @ObservedObject private var activity = NetworkActivity.shared
    @State private var expandedLabels: Set<String> = LabelExpansionStore.load()
    /// 被折叠的账户卡片（默认展开，记录“已折叠”）。
    @State private var collapsedAccounts: Set<String> = LabelExpansionStore.loadCollapsed()
    /// 待确认移除的账号。移除会删掉登录凭据和整份本地缓存，不该点一下就执行。
    @State private var pendingRemoval: Account?
    /// 各账号头右侧文字块的实际高度，头像按它定大小（按账号 id 记，行数因备注/回溯日期而异）。
    @State private var headerTextHeights: [String: CGFloat] = [:]

    /// 顶上分组卡片的内边距和它到侧栏边缘的距离。算侧栏最小宽度时要把这两圈加回去。
    private static let profileCardPadding: CGFloat = 4
    private static let profileCardInset: CGFloat = 10

    var body: some View {
        VStack(spacing: 0) {
            if !appState.accounts.isEmpty {
                // 顶上一张卡片：第一行是窗口的三个圆点（见 MainWindowChrome，它们浮在卡片上，
                // 中心在 y≈25），分组标签从第二行起排、排不下再折行。卡片顶边和中栏面板一样
                // 从 10pt 起，两栏的顶端就对齐了。
                SidebarCard(padding: Self.profileCardPadding) {
                    ProfileSwitcher()
                        .padding(.top, 24)
                }
                .padding([.top, .horizontal], Self.profileCardInset)
                // 分组标签排成一行要多宽，加上卡片内外的留白，就是侧栏不让标签折行的最小宽度
                .onPreferenceChange(ProfileSwitcherRowWidthKey.self) { rowWidth in
                    appState.sidebarMinWidth = rowWidth + (Self.profileCardPadding + Self.profileCardInset) * 2
                }
            }
            ScrollView {
                if appState.accounts.isEmpty {
                    emptyState
                } else if appState.activeAccounts.isEmpty {
                    emptyProfileState
                } else {
                    VStack(spacing: 12) {
                        smartMailboxCard
                        ForEach(appState.activeAccounts) { account in
                            accountCard(account)
                        }
                    }
                    // 顶上和分组卡片之间留的也是卡间距
                    .padding(EdgeInsets(top: 12, leading: 10, bottom: 10, trailing: 10))
                }
            }
        }
        .sheet(item: $appState.labelEditTarget) { target in
            LabelEditSheet(target: target)
                .environmentObject(labelStore)
        }
        // 与设置窗口里的移除走同一道确认，别处点得动的地方不该更宽松
        .alert("移除账号", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("移除", role: .destructive) {
                if let account = pendingRemoval {
                    mailStore.drop(account: account.id)
                    appState.removeAccount(account)
                }
                pendingRemoval = nil
            }
        } message: {
            Text("将从 Mgmail 移除「\(pendingRemoval?.email ?? "")」并删除其本地登录凭据与缓存。此操作不影响你的 Gmail 账户本身。")
        }
        .task(id: appState.activeAccounts.map(\.id)) {
            // 只补齐本地还没有的账号标签；已有缓存就直接用，要最新的走「获取新邮件」
            await withTaskGroup(of: Void.self) { group in
                for account in appState.activeAccounts {
                    group.addTask { await labelStore.loadIfNeeded(for: account.id) }
                }
            }
        }
        // 菜单栏「邮箱 → 获取新邮件」发来的同步请求。菜单拿不到这里的环境对象，
        // 只能经 AppState 转一手；落点放在侧栏，和工具栏、账号右键菜单的刷新走同一条路。
        .onChange(of: appState.syncRequest) { _, request in
            guard let request else { return }
            if let account = request.accountID {
                refresh(account)
            } else {
                refreshAll()
            }
        }
    }

    // MARK: - 智能邮箱（跨账号聚合）

    private var smartMailboxCard: some View {
        SidebarCard {
            HStack {
                Text("智能邮箱")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // 「获取所有新邮件」是全局动作，不属于哪个账号，放在跨账号这张卡的头上。
                // 单个账号的刷新在各自卡片的头像上。
                Button { refreshAll() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("获取所有新邮件（⇧⌘N）")
                .disabled(appState.activeAccounts.isEmpty)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
            // 汇总当前分组的所有账号。只放收件箱和星标——已发送、草稿、垃圾邮件、
            // 废纸篓都是「针对某个账号」才有意义的，去下面各账号自己的卡片里看。
            ForEach(StandardMailbox.smart) { box in
                MailboxRow(title: box.name, systemImage: box.systemImage,
                           selection: MailboxSelection(accountID: nil, labelID: box.id, labelName: box.name))
            }
        }
    }

    // MARK: - 账号卡片（账户 → 该账号的全部标签）

    private func accountCard(_ account: Account) -> some View {
        let tree = LabelTree.build(labelStore.userLabels(for: account.id))
        let categories = labelStore.categories(for: account.id)
        let collapsed = collapsedAccounts.contains(account.id)
        return SidebarCard {
            accountHeader(account, collapsed: collapsed)
            if !collapsed {
                // 该账号自己的固定邮箱：顶部是聚合视图，这里才能单看一个账号
                ForEach(StandardMailbox.all) { box in
                    MailboxRow(title: box.name, systemImage: box.systemImage,
                               selection: MailboxSelection(accountID: account.id, labelID: box.id,
                                                           labelName: "\(account.displayName) · \(box.name)"))
                }
                // 收件箱分类（主要/社交/推广…）：条目多且不常用，收进一个默认折叠的组
                if !categories.isEmpty {
                    let groupID = "cat:\(account.id)"
                    MailboxRow(title: "分类", systemImage: "square.grid.2x2", selection: nil,
                               disclosure: groupBinding(groupID))
                    if expandedLabels.contains(groupID) {
                        ForEach(categories) { category in
                            MailboxRow(title: category.name, systemImage: category.systemImage,
                                       selection: MailboxSelection(accountID: account.id, labelID: category.id,
                                                                   labelName: "\(account.displayName) · \(category.name)"),
                                       depth: 1)
                        }
                    }
                }
                ForEach(tree) { node in
                    LabelNodeView(node: node, accountID: account.id, expanded: $expandedLabels)
                }
            }
        }
    }

    private func accountHeader(_ account: Account, collapsed: Bool) -> some View {
        HStack(spacing: 8) {
            // 头像兼作该账号的刷新按钮：鼠标移上去变成刷新图标，点一下只刷这个账号。
            // 尺寸跟着右侧文字块走：有备注、有回溯日期的账号是三行，头像就跟着大；
            // 只有一行名字的账号头像也随之缩小。不撑满整行，留一点上下呼吸。
            AvatarRefreshButton(account: account,
                                size: avatarSize(for: account.id),
                                reloadToken: appState.avatarReloadToken) {
                refresh(account.id)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(account.displayName)
                    .font(.system(size: 12, weight: .medium))
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
                    Text("邮件自 \(DateText.backfill(oldest))")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                headerTextHeights[account.id] = height
            }
            Spacer(minLength: 4)
            // 该账号有请求在飞时转圈；空闲时留着同样大小的空位，转圈来去时文字不会跟着挪。
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.6)
                .frame(width: 12, height: 12)
                .opacity(activity.busyAccounts.contains(account.id) ? 1 : 0)
            DisclosureChevron(isExpanded: !collapsed)
        }
        .animation(.easeInOut(duration: 0.15), value: activity.busyAccounts.contains(account.id))
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        // 点账号头折叠/展开这张卡（头像那一小块除外，它是刷新）
        .onTapGesture { toggleCollapsed(account.id) }
        .help(account.email)
        .contextMenu {
            Button("获取新邮件") { refresh(account.id) }
            Divider()
            Button("新建标签…") {
                appState.labelEditTarget = LabelEditTarget(accountID: account.id, label: nil)
            }
            Divider()
            SettingsLink { Text("账号与分组…") }
            Button("移除账户…", role: .destructive) { pendingRemoval = account }
        }
    }

    /// 账号头像的边长：右侧文字块高度的八成，向下取整到偶数以免半像素发虚，下限 16pt。
    private func avatarSize(for account: String) -> CGFloat {
        guard let textHeight = headerTextHeights[account] else { return AvatarRefreshButton.minSize }
        let size = (textHeight * 0.8 / 2).rounded(.down) * 2
        return max(AvatarRefreshButton.minSize, size)
    }

    private func toggleCollapsed(_ id: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if collapsedAccounts.contains(id) { collapsedAccounts.remove(id) } else { collapsedAccounts.insert(id) }
        }
        LabelExpansionStore.saveCollapsed(collapsedAccounts)
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
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    /// 当前分组里一个账号都没有时的占位。
    private var emptyProfileState: some View {
        ContentUnavailableView {
            Label("该分组暂无账号", systemImage: "person.2.slash")
        } description: {
            Text("右键分组标签选「管理分组…」把账号加进来，或再点一次该标签回到全部账号")
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    /// 手动刷新一个账号：标签拉新，然后按位点同步邮件变化。
    private func refresh(_ account: String) {
        Task { await MailRefresh.account(account, labels: labelStore, mail: mailStore) }
    }

    /// 刷新当前分组里的全部账号。
    private func refreshAll() {
        let ids = appState.activeAccounts.map(\.id)
        Task { await MailRefresh.accounts(ids, labels: labelStore, mail: mailStore) }
    }

    /// 「分类」等次级分组的展开绑定（默认折叠，记录“已展开”，与标签树同一套持久化）。
    private func groupBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expandedLabels.contains(id) },
            set: { isOpen in
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isOpen { expandedLabels.insert(id) } else { expandedLabels.remove(id) }
                }
                LabelExpansionStore.save(expandedLabels)
            }
        )
    }
}

// MARK: - 卡片与行

/// 侧栏里的一张悬浮卡片：玻璃材质、圆角、和邻卡之间留空（材质见 GlassCard）。
private struct SidebarCard<Content: View>: View {
    var padding: CGFloat = 5
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

/// 卡片里的一行邮箱/标签。选中时铺一层强调色，鼠标悬停时淡淡提亮。
///
/// `selection` 为 nil 的行不可选（纯中间层、「分类」这类只负责展开收起的组头）。
/// 带 `disclosure` 的行右端有个小箭头，点整行切换展开。
private struct MailboxRow<Icon: View>: View {
    let title: String
    let icon: Icon
    let selection: MailboxSelection?
    var depth: Int = 0
    var disclosure: Binding<Bool>? = nil
    @EnvironmentObject private var appState: AppState
    @State private var hovering = false

    init(title: String, systemImage: String, selection: MailboxSelection?,
         depth: Int = 0, disclosure: Binding<Bool>? = nil) where Icon == Image {
        self.title = title
        self.icon = Image(systemName: systemImage)
        self.selection = selection
        self.depth = depth
        self.disclosure = disclosure
    }

    init(title: String, selection: MailboxSelection?, depth: Int = 0,
         disclosure: Binding<Bool>? = nil, @ViewBuilder icon: () -> Icon) {
        self.title = title
        self.icon = icon()
        self.selection = selection
        self.depth = depth
        self.disclosure = disclosure
    }

    private var isSelected: Bool {
        guard let selection, let current = appState.selection else { return false }
        return current.accountID == selection.accountID && current.labelID == selection.labelID
    }

    var body: some View {
        HStack(spacing: 8) {
            icon
                .font(.system(size: 13))
                .frame(width: 18)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let disclosure {
                DisclosureChevron(isExpanded: disclosure.wrappedValue, onSelection: isSelected)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(isSelected ? Color.white : (selection == nil ? Color.secondary : Color.primary))
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .padding(.leading, CGFloat(depth) * 16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor : (hovering ? Color.primary.opacity(0.06) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if let disclosure {
                disclosure.wrappedValue.toggle()
            } else if let selection {
                appState.selection = selection
            }
        }
        .onHover { hovering = $0 }
    }
}

/// 展开/折叠指示：向右的小箭头，展开时转成向下。
private struct DisclosureChevron: View {
    let isExpanded: Bool
    /// 落在选中行（强调色底）上时用白色，否则次要色。
    var onSelection = false
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(onSelection ? Color.white : Color.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .frame(width: 12)
            .accessibilityLabel(isExpanded ? "折叠" : "展开")
    }
}

/// 账号头像，鼠标悬停时变成刷新按钮，点击刷新该账号。
///
/// 平时就是普通头像，不占额外位置；悬停才换成刷新图标，所以不会让账号行显得像一排按钮。
private struct AvatarRefreshButton: View {
    /// 文字块再矮头像也不小于这个尺寸，和别处的 16pt 小头像持平。
    static let minSize: CGFloat = 16

    let account: Account
    let size: CGFloat
    let reloadToken: Int
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                AccountAvatar(account: account, size: size, reloadToken: reloadToken)
                    .opacity(hovering ? 0 : 1)
                if hovering {
                    Circle()
                        .fill(Color.accentColor)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            // 点击区域比头像放宽一圈，不用瞄得那么准
            .contentShape(Circle().inset(by: -3))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .help("获取新邮件")
    }
}

/// 递归渲染一个标签节点：有子节点时行尾带展开箭头，展开后子节点缩进一级列在下面。
private struct LabelNodeView: View {
    let node: LabelNode
    let accountID: String
    @Binding var expanded: Set<String>
    var depth = 0
    @EnvironmentObject private var appState: AppState

    var body: some View {
        interactiveRow
        if !node.children.isEmpty, expanded.contains(node.id) {
            ForEach(node.children) { child in
                LabelNodeView(node: child, accountID: accountID, expanded: $expanded, depth: depth + 1)
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

    /// 单行标签（显示末段名 + 颜色标记），有真实标签时可被选中；有子节点时点行尾箭头展开。
    ///
    /// 有子节点又有真实标签的中间层，点行选中、点箭头展开，两件事分开。
    private var row: some View {
        let label = node.label
        let selection = label.map {
            MailboxSelection(accountID: accountID, labelID: $0.id, labelName: $0.name)
        }
        return MailboxRow(title: node.title, selection: selection, depth: depth,
                          disclosure: node.children.isEmpty || selection != nil ? nil : expandBinding) {
            Image(systemName: label?.uiColor == nil ? "tag" : "tag.fill")
                .foregroundStyle(label?.uiColor ?? Color.secondary)
        }
        .overlay(alignment: .trailing) {
            // 可选中的中间层：箭头单独成一个按钮，不和选中抢同一次点击
            if !node.children.isEmpty, let selection {
                let selected = appState.selection?.accountID == selection.accountID
                    && appState.selection?.labelID == selection.labelID
                Button { expandBinding.wrappedValue.toggle() } label: {
                    DisclosureChevron(isExpanded: expanded.contains(node.id), onSelection: selected)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var expandBinding: Binding<Bool> {
        Binding(
            get: { expanded.contains(node.id) },
            set: { isOn in
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isOn { expanded.insert(node.id) } else { expanded.remove(node.id) }
                }
                LabelExpansionStore.save(expanded)
            }
        )
    }
}
