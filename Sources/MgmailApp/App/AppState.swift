import SwiftUI
import Combine

/// 应用根状态。管理账户、当前选中的邮箱/会话，以及登录流程状态。
@MainActor
final class AppState: ObservableObject {
    /// 已登录账户列表。
    @Published var accounts: [Account] = []

    /// 账号分组（Profile）列表。
    @Published var profiles: [Profile] = []

    /// 当前选中的 Profile id；`nil` 表示内置「全部」聚合（显示所有账号）。
    @Published var currentProfileID: String? {
        didSet { ProfileStore.saveCurrentID(currentProfileID) }
    }

    /// 当前分组下参与聚合/侧栏的账号。「全部」态返回所有账号；选中某分组时返回其成员（按账号列表顺序）。
    var activeAccounts: [Account] {
        guard let pid = currentProfileID,
              let profile = profiles.first(where: { $0.id == pid }) else {
            return accounts
        }
        let members = Set(profile.memberEmails)
        return accounts.filter { members.contains($0.email) }
    }

    /// 尚未归入任何分组的账号（仅在「全部」里可见）。
    var ungroupedAccounts: [Account] {
        let grouped = Set(profiles.flatMap(\.memberEmails))
        return accounts.filter { !grouped.contains($0.email) }
    }

    /// 当前侧栏选中的邮箱/标签。
    @Published var selection: MailboxSelection?

    /// 当前中栏选中的会话集合（支持多选批量操作）。
    @Published var selectedThreads: Set<SelectedThread> = []

    /// 恰好选中一封时返回它（用于右栏详情）。
    var singleSelection: SelectedThread? {
        selectedThreads.count == 1 ? selectedThreads.first : nil
    }

    /// 新写一封信时用哪个账号发。
    ///
    /// 优先当前正看着的那封邮件所属账号，其次是侧栏选中的账号，最后退到第一个。
    /// 「全部」这类聚合视图的 `accountID` 是 nil，落到最后一档。
    var composeAccount: Account? {
        let candidates = activeAccounts
        if let id = singleSelection?.accountID,
           let hit = candidates.first(where: { $0.id == id }) { return hit }
        if let id = selection?.accountID,
           let hit = candidates.first(where: { $0.id == id }) { return hit }
        return candidates.first
    }

    /// 当前选中会话的摘要信息（供多选时右栏画叠加卡片），按列表顺序。
    @Published var selectedInfos: [SelectedThreadInfo] = []

    /// 是否正在进行登录授权。
    @Published var isSigningIn = false

    /// 登录/运行期错误提示。
    @Published var errorMessage: String?

    /// 是否已配置 OAuth 客户端（oauth_client.json 是否存在且可解析）。
    @Published var hasOAuthConfig: Bool = false


    /// 详情栏发起的删除请求，由中栏列表执行（复用列表的移除 + 自动选中下一封逻辑）。
    @Published var trashRequest: ThreadRequest?
    private var requestToken = 0

    /// 侧栏「刷新」按钮发来的同步请求，由中栏列表执行。
    @Published var syncRequest: SyncRequest?
    private var syncToken = 0

    /// 头像缓存更新计数（下载完成后自增，驱动头像视图刷新）。
    @Published var avatarReloadToken = 0

    /// 正在编辑/新建的标签（驱动标签编辑面板）。
    @Published var labelEditTarget: LabelEditTarget?

    /// 请求删除某封邮件/会话（由中栏列表实际执行）。
    func requestTrash(account: String, id: String) {
        requestToken += 1
        trashRequest = ThreadRequest(account: account, id: id, token: requestToken)
    }

    /// 请求同步（侧栏刷新按钮）。`account` 为 nil 表示当前列表涉及的全部账号。
    func requestSync(account: String?) {
        syncToken += 1
        syncRequest = SyncRequest(accountID: account, token: syncToken)
    }


    init() {
        accounts = AccountStore.load()
        profiles = ProfileStore.load()
        // 恢复上次选中的分组；若指向已不存在的分组则回落到「全部」。
        let savedID = ProfileStore.loadCurrentID()
        currentProfileID = profiles.contains { $0.id == savedID } ? savedID : nil
        hasOAuthConfig = GoogleConfig.load() != nil
        // 磁盘布局的一次性迁移与陈旧文件清理。必须同步跑在任何缓存读写之前，
        // 否则会照着旧路径读出空结果、再照新路径写一份，等于把数据劈成两半。
        StorageMigration.run(accounts: accounts.map(\.email))
        // 正文缓存的回收。纯磁盘操作，放后台，不挡启动。
        Task { await MailCache.shared.reclaim() }
        selectDefaultInboxIfNeeded()
    }

    // MARK: - Profile 分组管理（互斥归属）

    /// 切换当前分组。若原选中的是某个不在新分组内的具体账号，回落到聚合收件箱，并清理越界的多选。
    func setCurrentProfile(_ id: String?) {
        currentProfileID = id
        if let accID = selection?.accountID,
           !activeAccounts.contains(where: { $0.id == accID }) {
            selection = MailboxSelection(accountID: nil, labelID: "INBOX", labelName: "收件箱")
        }
        let activeIDs = Set(activeAccounts.map(\.id))
        selectedThreads = selectedThreads.filter { activeIDs.contains($0.accountID) }
    }

    /// 新建分组并立即切换过去。颜色按现有分组数轮转取色。
    @discardableResult
    func addProfile(name: String) -> Profile {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = Profile(name: trimmed.isEmpty ? "新分组" : trimmed,
                              colorIndex: profiles.count % Profile.palette.count)
        profiles.append(profile)
        ProfileStore.save(profiles)
        setCurrentProfile(profile.id)
        return profile
    }

    /// 重命名分组。
    func renameProfile(_ id: String, to name: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        profiles[idx].name = trimmed
        ProfileStore.save(profiles)
    }

    /// 更换分组颜色。
    func setProfileColor(_ id: String, colorIndex: Int) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].colorIndex = colorIndex
        ProfileStore.save(profiles)
    }

    /// 把分组 `id` 移动到 `targetID` 之前/之后（拖动排序用）。
    /// `after` 为 true 表示放到目标右侧。同一个分组拖到自己身上时不做任何事。
    func moveProfile(_ id: String, relativeTo targetID: String, after: Bool) {
        guard id != targetID,
              let from = profiles.firstIndex(where: { $0.id == id }) else { return }
        let moved = profiles.remove(at: from)
        // 移除后再定位目标，索引才是准的。
        guard let target = profiles.firstIndex(where: { $0.id == targetID }) else {
            profiles.insert(moved, at: min(from, profiles.count))
            return
        }
        profiles.insert(moved, at: after ? target + 1 : target)
        ProfileStore.save(profiles)
    }

    /// 把分组移到末尾（拖到标签条空白处时用）。
    func moveProfileToEnd(_ id: String) {
        guard let from = profiles.firstIndex(where: { $0.id == id }) else { return }
        let moved = profiles.remove(at: from)
        profiles.append(moved)
        ProfileStore.save(profiles)
    }

    /// 删除分组（不删账号本身）。若删的是当前分组，回落到「全部」。
    func deleteProfile(_ id: String) {
        profiles.removeAll { $0.id == id }
        ProfileStore.save(profiles)
        if currentProfileID == id { setCurrentProfile(nil) }
    }

    /// 把某账号归入某分组（`profileID == nil` 表示移出分组，回到「未分组」）。
    /// 互斥：加入前先从其它所有分组移除。
    func assignAccount(_ email: String, toProfile profileID: String?) {
        for i in profiles.indices {
            profiles[i].memberEmails.removeAll { $0 == email }
        }
        if let profileID, let idx = profiles.firstIndex(where: { $0.id == profileID }) {
            profiles[idx].memberEmails.append(email)
        }
        ProfileStore.save(profiles)
        // 归属变化后，当前分组的可见账号可能变化，纠正越界的选择。
        setCurrentProfile(currentProfileID)
    }

    /// 查询某账号当前所属分组 id（未分组返回 nil）。
    func profileID(ofAccount email: String) -> String? {
        profiles.first { $0.memberEmails.contains(email) }?.id
    }

    /// 若尚未选择邮箱且已有账户，默认选中「聚合收件箱」（跨账号，不自动选中任何邮件）。
    func selectDefaultInboxIfNeeded() {
        guard selection == nil, !accounts.isEmpty else { return }
        selection = MailboxSelection(accountID: nil, labelID: "INBOX", labelName: "收件箱")
    }

    /// 更新账户显示名。
    func setDisplayName(_ name: String, for id: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].displayName = name
        AccountStore.save(accounts)
    }

    /// 更新账户备注。
    func setNote(_ note: String, for id: String) {
        guard let idx = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[idx].note = note
        AccountStore.save(accounts)
    }

    /// 重新检测 OAuth 配置文件（用户放好文件后调用）。
    func refreshConfigStatus() {
        hasOAuthConfig = GoogleConfig.load() != nil
    }

    /// 进行中的登录任务（便于取消放弃的登录）。
    private var signInTask: Task<Void, Never>?

    /// 触发一次 OAuth 登录，成功后加入账户列表。再次调用会取消上一次未完成的登录并重新开始。
    func addAccount() {
        guard let config = GoogleConfig.load() else {
            errorMessage = OAuthError.missingConfig.errorDescription
            hasOAuthConfig = false
            return
        }
        signInTask?.cancel() // 取消上一次未完成的登录（关闭旧回环服务器）
        isSigningIn = true
        errorMessage = nil
        signInTask = Task {
            do {
                let result = try await OAuthClient(config: config).signIn()
                // 存 refresh token 到 Keychain，access token 到内存缓存
                TokenStore.saveRefreshToken(result.refreshToken, for: result.email)
                await AuthManager.shared.store(result)

                // 已存在则更新头像 URL（保留用户改过的显示名/备注）；否则新增
                if let idx = accounts.firstIndex(where: { $0.id == result.email }) {
                    accounts[idx].avatarURL = result.pictureURL
                } else {
                    let fallback = result.email.split(separator: "@").first.map(String.init) ?? result.email
                    let name = (result.name?.isEmpty == false) ? result.name! : fallback
                    accounts.append(Account(email: result.email, displayName: name, avatarURL: result.pictureURL))
                }
                AccountStore.save(accounts)
                selectDefaultInboxIfNeeded()
                isSigningIn = false

                // 下载头像并缓存（成功后刷新头像视图）
                if let picture = result.pictureURL {
                    let email = result.email
                    Task {
                        if await AvatarStore.download(from: picture, for: email) {
                            avatarReloadToken += 1
                        }
                    }
                }
            } catch is CancellationError {
                // 本次登录被放弃/被新的登录取代：不报错，也不动状态（新任务会自行管理）
            } catch {
                // 仅当当前没有更新的登录在进行时才复位（避免旧任务超时后误清新任务的状态）
                if !Task.isCancelled {
                    errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    isSigningIn = false
                }
            }
        }
    }

    /// 移除账户及其令牌。
    func removeAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        AccountStore.save(accounts)
        // 从所有分组成员中移除该账号（分组本身保留）。
        var profilesChanged = false
        for i in profiles.indices where profiles[i].memberEmails.contains(account.email) {
            profiles[i].memberEmails.removeAll { $0 == account.email }
            profilesChanged = true
        }
        if profilesChanged { ProfileStore.save(profiles) }
        TokenStore.deleteRefreshToken(for: account.email)
        AvatarStore.remove(for: account.email)
        Task {
            await AuthManager.shared.clear(account.email)
            await MailCache.shared.clear(account: account.email)
        }
        if selection?.accountID == account.id { selection = nil }
        selectedThreads = selectedThreads.filter { $0.accountID != account.id }
        selectDefaultInboxIfNeeded()
    }
}

/// 侧栏选中项：某账户下的某个邮箱/标签。`accountID == nil` 表示跨账号聚合。
struct MailboxSelection: Hashable {
    let accountID: String?
    let labelID: String
    let labelName: String
}

/// 中栏选中的会话（带来源账号）。拖拽载荷会编码它，故需 Codable。
struct SelectedThread: Hashable, Codable {
    let accountID: String
    let threadID: String
}

/// 标签编辑目标：`label` 为 nil 表示在该账号下新建标签。
struct LabelEditTarget: Identifiable {
    let id = UUID()
    let accountID: String
    let label: GmailLabel?
}

/// 选中会话的摘要信息（用于多选叠加卡片）。
struct SelectedThreadInfo: Hashable {
    let accountID: String
    let threadID: String
    let from: String
    let subject: String
    let date: Date?
}

/// 由详情栏发起、交给列表执行的操作请求。
struct ThreadRequest: Equatable {
    let account: String
    let id: String
    let token: Int
}

/// 由侧栏发起、交给列表执行的同步请求（`accountID` 为 nil 表示全部账号）。
struct SyncRequest: Equatable {
    let accountID: String?
    let token: Int
}

/// 应用内拖拽的上下文，用于放置目标提前判断兼容性。
enum DragContext: Equatable {
    /// 从侧栏拖出的一个标签。
    case label(accountID: String, labelID: String, name: String)
}
