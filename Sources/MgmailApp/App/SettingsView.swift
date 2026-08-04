import SwiftUI

/// 应用偏好设置的存储 key，集中管理避免字符串散落。
enum SettingsKey {
    /// 是否默认加载邮件中的远程内容（图片/样式等）。默认开启。
    static let loadRemoteContentByDefault = "loadRemoteContentByDefault"
    /// 设置窗口上次停留的标签页（用于从菜单/右键直达对应页）。
    static let settingsTab = "settings.selectedTab"
}

/// 设置窗口的标签页。
enum SettingsTab: String {
    case accounts, profiles, privacy
}

/// 设置窗口（⌘,）：账号、分组、隐私三页。
struct SettingsView: View {
    @AppStorage(SettingsKey.loadRemoteContentByDefault) private var loadRemoteByDefault = true
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
