import SwiftUI

/// 标准邮箱定义（映射到 Gmail 系统标签）。
struct StandardMailbox: Identifiable, Hashable {
    let id: String                 // 选择用的标识
    let name: String
    let systemImage: String
    /// 传给 Gmail API 的 labelId；nil 表示不按标签过滤（「所有邮件」）。
    var apiLabelID: String?
    /// 是否需要包含 SPAM/TRASH（按这两个标签过滤时必须为 true）。
    var includeSpamTrash: Bool = false

    /// 「所有邮件」的特殊标识。
    static let allMailID = "ALL_MAIL"

    static let all: [StandardMailbox] = [
        .init(id: "INBOX", name: "收件箱", systemImage: "tray", apiLabelID: "INBOX"),
        .init(id: "STARRED", name: "已加星标", systemImage: "star", apiLabelID: "STARRED"),
        .init(id: "SENT", name: "已发送", systemImage: "paperplane", apiLabelID: "SENT"),
        .init(id: "DRAFT", name: "草稿", systemImage: "doc", apiLabelID: "DRAFT"),
        .init(id: allMailID, name: "所有邮件", systemImage: "tray.full", apiLabelID: nil),
        .init(id: "SPAM", name: "垃圾邮件", systemImage: "xmark.bin", apiLabelID: "SPAM", includeSpamTrash: true),
        .init(id: "TRASH", name: "废纸篓", systemImage: "trash", apiLabelID: "TRASH", includeSpamTrash: true),
    ]
}

/// 左栏：账户与邮箱/标签。
///
/// 结构（仿常见邮件客户端）：
/// - 固定标签：一级按标签本身聚合，二级按账户（多账户时可折叠，默认展开）。
/// - 自定义标签：按账户聚合，每个账户一个分组（内含标签层级树）。
struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var labelStore: LabelStore
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
            } else {
                fixedLabelsSection
                customLabelsSections
            }
        }
        .listStyle(.sidebar)
        .sheet(item: $appState.labelEditTarget) { target in
            LabelEditSheet(target: target)
                .environmentObject(labelStore)
        }
        .task(id: appState.accounts.map(\.id)) {
            // 并发加载各账号标签：每个都先用缓存瞬时 seed，避免串行等第一个网络刷新完
            await withTaskGroup(of: Void.self) { group in
                for account in appState.accounts {
                    group.addTask { await labelStore.load(for: account.id) }
                }
            }
        }
    }

    // MARK: - 固定标签（标签 → 账户）

    @ViewBuilder
    private var fixedLabelsSection: some View {
        Section("邮箱") {
            if appState.accounts.count == 1, let only = appState.accounts.first {
                // 单账户直接平铺，避免多余的一层嵌套
                ForEach(StandardMailbox.all) { box in
                    Label(box.name, systemImage: box.systemImage)
                        .tag(MailboxSelection(accountID: only.id, labelID: box.id, labelName: box.name))
                }
            } else {
                // 多账户：点标签名看跨账号聚合，展开可选单个账号；默认折叠。
                ForEach(StandardMailbox.all) { box in
                    DisclosureGroup(isExpanded: groupBinding("mbx:\(box.id)")) {
                        ForEach(appState.accounts) { account in
                            accountMailboxRow(account, box)
                        }
                    } label: {
                        Label(box.name, systemImage: box.systemImage)
                            .tag(MailboxSelection(accountID: nil, labelID: box.id, labelName: box.name))
                    }
                }
            }
        }
    }

    /// 固定标签下某账户的一行。
    private func accountMailboxRow(_ account: Account, _ box: StandardMailbox) -> some View {
        HStack(spacing: 6) {
            AccountAvatar(account: account, size: 14, reloadToken: appState.avatarReloadToken)
            Text(account.displayName).lineLimit(1).truncationMode(.middle)
        }
        .help(account.email)
        .tag(MailboxSelection(accountID: account.id, labelID: box.id, labelName: "\(account.displayName) · \(box.name)"))
    }

    // MARK: - 自定义标签（账户 → 标签树）

    @ViewBuilder
    private var customLabelsSections: some View {
        ForEach(appState.accounts) { account in
            let tree = LabelTree.build(labelStore.userLabels(for: account.id))
            // 可折叠：点账号名（分组头）隐藏/展开该账号的标签列表。默认展开。
            Section(isExpanded: accountBinding(account.id)) {
                if tree.isEmpty {
                    Text("无自定义标签").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(tree) { node in
                        LabelNodeView(node: node, accountID: account.id, expanded: $expandedLabels)
                    }
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
                Text("从菜单栏「账号 → 账号管理」添加你的 Gmail")
            } else {
                Text("先完成 OAuth 配置，再添加账户")
            }
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
            }
        }
        .help(account.email)
        .contextMenu {
            Button("新建标签…") {
                appState.labelEditTarget = LabelEditTarget(accountID: account.id, label: nil)
            }
            Divider()
            Button("账号管理…") { appState.showAccountManager = true }
            Button("移除账户", role: .destructive) { appState.removeAccount(account) }
        }
    }

    /// 固定邮箱分组的展开绑定（默认折叠，记录“已展开”，与标签树同一套持久化）。
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
            row.contextMenu { labelMenu }
        } else {
            DisclosureGroup(isExpanded: expandBinding) {
                ForEach(node.children) { child in
                    LabelNodeView(node: child, accountID: accountID, expanded: $expanded)
                }
            } label: {
                row.contextMenu { labelMenu }
            }
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
