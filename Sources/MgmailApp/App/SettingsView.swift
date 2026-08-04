import SwiftUI

/// 应用偏好设置的存储 key，集中管理避免字符串散落。
enum SettingsKey {
    /// 是否默认加载邮件中的远程内容（图片/样式等）。默认开启。
    static let loadRemoteContentByDefault = "loadRemoteContentByDefault"
}

/// 设置窗口（⌘,）。目前包含「隐私」一项：默认远程内容加载开关。
struct SettingsView: View {
    @AppStorage(SettingsKey.loadRemoteContentByDefault) private var loadRemoteByDefault = true

    var body: some View {
        TabView {
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
        }
        .frame(width: 460, height: 220)
    }
}
