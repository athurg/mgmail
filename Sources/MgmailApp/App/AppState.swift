import SwiftUI
import Combine

/// 应用根状态。管理账户、当前选中的邮箱/会话，以及登录流程状态。
@MainActor
final class AppState: ObservableObject {
    /// 已登录账户列表。
    @Published var accounts: [Account] = []

    /// 当前侧栏选中的邮箱/标签。
    @Published var selection: MailboxSelection?

    /// 当前中栏选中的会话集合（支持多选批量操作）。
    @Published var selectedThreads: Set<SelectedThread> = []

    /// 恰好选中一封时返回它（用于右栏详情）。
    var singleSelection: SelectedThread? {
        selectedThreads.count == 1 ? selectedThreads.first : nil
    }

    /// 当前选中会话的摘要信息（供多选时右栏画叠加卡片），按列表顺序。
    @Published var selectedInfos: [SelectedThreadInfo] = []

    /// 是否正在进行登录授权。
    @Published var isSigningIn = false

    /// 登录/运行期错误提示。
    @Published var errorMessage: String?

    /// 是否已配置 OAuth 客户端（oauth_client.json 是否存在且可解析）。
    @Published var hasOAuthConfig: Bool = false

    /// 会话被修改（读/星标/标签/归档）后广播，供列表刷新对应行。
    @Published var lastThreadChange: ThreadChange?
    private var changeToken = 0

    /// 是否展示账号管理面板。
    @Published var showAccountManager = false

    /// 头像缓存更新计数（下载完成后自增，驱动头像视图刷新）。
    @Published var avatarReloadToken = 0

    /// 正在编辑/新建的标签（驱动标签编辑面板）。
    @Published var labelEditTarget: LabelEditTarget?

    /// 广播某会话发生了变化。
    func threadDidChange(account: String, id: String) {
        changeToken += 1
        lastThreadChange = ThreadChange(account: account, id: id, token: changeToken)
    }

    init() {
        accounts = AccountStore.load()
        hasOAuthConfig = GoogleConfig.load() != nil
        // 一次性迁移旧钥匙串 token 到文件存储（迁移完成后可移除本行与 TokenMigration.swift）
        TokenMigration.migrateFromKeychain(emails: accounts.map(\.email))
        selectDefaultInboxIfNeeded()
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

/// 中栏选中的会话（带来源账号）。
struct SelectedThread: Hashable {
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

/// 会话变更事件。
struct ThreadChange: Equatable {
    let account: String
    let id: String
    let token: Int
}
