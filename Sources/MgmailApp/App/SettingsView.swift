import SwiftUI

/// 应用偏好设置的存储 key，集中管理避免字符串散落。
enum SettingsKey {
    /// 是否默认加载邮件中的远程内容（图片/样式等）。默认开启。
    static let loadRemoteContentByDefault = "loadRemoteContentByDefault"
    /// 是否按会话（Thread）合并显示邮件。默认关闭，即每行只显示一封邮件。
    static let conversationView = "conversationView"
    /// 设置窗口上次停留的标签页（用于从菜单/右键直达对应页）。
    static let settingsTab = "settings.selectedTab"
    /// 列表右上角的已读/未读过滤（记住上次选择，非设置窗口里的项）。
    static let readFilter = "threadList.readFilter"
}

/// 设置窗口的标签页。
enum SettingsTab: String {
    case accounts, profiles, display, privacy
}

/// 设置窗口（⌘,）：账号、分组、显示、隐私四页。
struct SettingsView: View {
    @AppStorage(SettingsKey.loadRemoteContentByDefault) private var loadRemoteByDefault = true
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

            Form {
                Section {
                    Toggle("默认加载邮件中的远程内容", isOn: $loadRemoteByDefault)
                    Text("关闭后，含远程图片/样式的邮件会先阻止加载，并在正文上方显示提示，需手动点击「加载远程内容」。开启可获得完整排版，但可能被发件人用于追踪你是否已读。")
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
