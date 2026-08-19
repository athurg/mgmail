import SwiftUI

/// 应用偏好设置的存储 key，集中管理避免字符串散落。
enum SettingsKey {
    /// 是否默认加载邮件中的远程内容（图片/样式等）。默认关闭，与 Apple Mail 一致。
    ///
    /// 关闭不只是为了隐私：WebKit 在远程资源加载完之前不渲染任何内容，
    /// 一封带几个外链图片的邮件，正文要等上一两秒才出得来；挡掉之后是秒开。
    static let loadRemoteContentByDefault = "loadRemoteContentByDefault"
    /// 是否按会话（Thread）合并显示邮件。默认关闭，即每行只显示一封邮件。
    static let conversationView = "conversationView"
    /// 设置窗口上次停留的标签页（用于从菜单/右键直达对应页）。
    static let settingsTab = "settings.selectedTab"
    /// 列表右上角的已读/未读过滤（记住上次选择，非设置窗口里的项）。
    static let readFilter = "threadList.readFilter"
    /// 本地搜索的范围：当前邮箱还是所有邮件（记住上次选择，非设置窗口里的项）。
    static let searchScope = "threadList.searchScope"
    /// 每个账户最多回溯多少封邮件。
    static let backfillLimit = "sync.backfillLimit"
    /// 每个账户最多回溯多少天。
    static let backfillDays = "sync.backfillDays"
    /// 新邮件通知总开关。
    static let notifyEnabled = "notify.enabled"
    /// 只通知「主要」邮件（推广/社交/论坛不弹）。
    static let notifyMainCategoryOnly = "notify.mainCategoryOnly"
    /// 通知带提示音。
    static let notifySound = "notify.sound"
    /// 在 Dock 图标上显示未读数。
    static let notifyDockBadge = "notify.dockBadge"
    /// 被静音的账号（邮箱地址数组）。
    static let notifyMutedAccounts = "notify.mutedAccounts"
}

/// 设置窗口的标签页。
enum SettingsTab: String {
    case accounts, profiles, display, sync, notifications, privacy
}

/// 设置窗口（⌘,）：账号、分组、显示、隐私四页。
struct SettingsView: View {
    @AppStorage(SettingsKey.loadRemoteContentByDefault) private var loadRemoteByDefault = false
    @AppStorage(SettingsKey.conversationView) private var conversationView = false
    @AppStorage(SettingsKey.settingsTab) private var selectedTab = SettingsTab.accounts.rawValue

    var body: some View {
        TabView(selection: $selectedTab) {
            AccountSettingsPane()
                .tabItem { Label("账号", systemImage: "person.crop.circle") }
                .tag(SettingsTab.accounts.rawValue)

            ProfileSettingsPane()
                .tabItem { Label("分组", systemImage: "square.stack") }
                .tag(SettingsTab.profiles.rawValue)

            Form {
                Section {
                    Toggle("按会话显示邮件", isOn: $conversationView)
                    Text("开启后，同一会话的往来邮件合并为一行，打开时按时间顺序展示整串对话。关闭时（默认）列表里每行就是一封独立邮件，打开只显示当前这一封。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("会话")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("显示", systemImage: "list.bullet.rectangle") }
            .tag(SettingsTab.display.rawValue)

            SyncSettingsPane()
                .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                .tag(SettingsTab.sync.rawValue)

            NotificationSettingsPane()
                .tabItem { Label("通知", systemImage: "bell") }
                .tag(SettingsTab.notifications.rawValue)

            Form {
                Section {
                    Toggle("默认加载邮件中的远程内容", isOn: $loadRemoteByDefault)
                    Text("默认关闭。含远程图片/样式的邮件会先阻止加载，并在正文上方显示提示，需手动点击「加载远程内容」。开启可获得完整排版，代价有两个：可能被发件人用追踪像素得知你已读，以及正文要等这些图片下载完才显示——带外链图片的邮件因此会慢上一两秒。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("远程内容")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("隐私", systemImage: "hand.raised") }
            .tag(SettingsTab.privacy.rawValue)
        }
        .frame(width: 500, height: 420)
    }
}

/// 同步设置：回溯范围。
///
/// 邮件按账户整批拉进本地，各个邮箱只是对它的过滤视图，所以「拉多少」是一个
/// 账户级的问题，与具体邮箱无关。范围越大越全，代价是首次同步更久、占用更多磁盘。
struct SyncSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mailStore: MailStore
    @AppStorage(SettingsKey.backfillLimit) private var limit = 500
    @AppStorage(SettingsKey.backfillDays) private var days = 90

    private static let limits = [200, 500, 1000, 2000, 5000]
    private static let dayChoices = [30, 90, 180, 365, 730]

    var body: some View {
        Form {
            Section {
                Picker("最多回溯邮件数", selection: $limit) {
                    ForEach(Self.limits, id: \.self) { Text("\($0) 封").tag($0) }
                }
                Picker("最多回溯时间", selection: $days) {
                    ForEach(Self.dayChoices, id: \.self) { Text(dayText($0)).tag($0) }
                }
                Text("每个账户按时间从新往旧拉取邮件，两个条件谁先到就停在哪。列表里各个邮箱都是对这批邮件的过滤，因此回溯范围之外的邮件不会出现——已发送、某个冷门标签这类邮箱可能因此是空的。调大后会在下次刷新时继续往前补。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("回溯范围")
            }

            Section {
                ForEach(appState.accounts) { account in
                    LabeledContent(account.displayName) {
                        Text(rangeText(account.id))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("已回溯到")
            }
        }
        .formStyle(.grouped)
    }

    private func dayText(_ days: Int) -> String {
        switch days {
        case ..<365: return "\(days) 天"
        case 365: return "1 年"
        default: return "\(days / 365) 年"
        }
    }

    private func rangeText(_ account: String) -> String {
        guard let oldest = mailStore.oldestDate(account: account) else { return "尚未同步" }
        return DateText.fullDate(oldest)
    }
}
