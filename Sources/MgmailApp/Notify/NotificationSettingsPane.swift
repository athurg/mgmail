import SwiftUI

/// 设置 → 通知。
///
/// 「哪些账号」放在这一页而不是账号页：通知是一件事，一件事的开关聚在一起，
/// 比散在各个账号的详情里好找。
struct NotificationSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mailStore: MailStore
    @ObservedObject private var permission = NotificationPermission.shared

    @AppStorage(SettingsKey.notifyEnabled) private var enabled = true
    @AppStorage(SettingsKey.notifyMainCategoryOnly) private var mainOnly = true
    @AppStorage(SettingsKey.notifySound) private var sound = true
    @AppStorage(SettingsKey.notifyDockBadge) private var dockBadge = true
    /// 静音名单存的是数组，`@AppStorage` 接不了，自己拿一份镜像。
    @State private var muted: Set<String> = NotifyPolicy.mutedAccounts

    var body: some View {
        Form {
            Section {
                Toggle("收到新邮件时通知", isOn: $enabled)
                Toggle("只通知主要邮件", isOn: $mainOnly)
                    .disabled(!enabled)
                Text("开启后，被 Gmail 归入「推广」「社交」「论坛」的邮件不再弹出通知。「更新」一类不在其中——订单确认、验证码、服务告警都落在那里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("播放提示音", isOn: $sound)
                    .disabled(!enabled)
            } header: {
                Text("新邮件")
            } footer: {
                permissionFooter
            }

            Section {
                Toggle("在 Dock 图标上显示未读数", isOn: $dockBadge)
                    .onChange(of: dockBadge) { _, _ in mailStore.refreshBadge() }
                Text("统计所有账号收件箱里的未读邮件，不随当前分组变化。这一项不需要通知权限，即使拒绝了通知也能用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Dock 角标")
            }

            Section {
                if appState.accounts.isEmpty {
                    Text("尚未添加账号。")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.accounts) { account in
                        Toggle(isOn: binding(for: account.id)) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.displayName)
                                Text(account.email)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!enabled)
                    }
                }
            } header: {
                Text("按账号")
            } footer: {
                Text("关掉某个账号后，它的新邮件既不弹通知，也不计入 Dock 角标。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await permission.refresh() }
        // 别的地方（比如另一台设备同步过来）改了名单时跟上
        .onAppear { muted = NotifyPolicy.mutedAccounts }
    }

    /// 开关是「开启通知」，存的却是静音名单，所以两头是反的。
    private func binding(for account: String) -> Binding<Bool> {
        Binding(
            get: { !muted.contains(account) },
            set: { on in
                NotifyPolicy.setMuted(!on, account: account)
                muted = NotifyPolicy.mutedAccounts
                mailStore.refreshBadge()
            }
        )
    }

    @ViewBuilder
    private var permissionFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(permission.summary)
                .font(.caption)
                .foregroundStyle(permission.isDenied ? .orange : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            if permission.isDenied {
                // 被拒之后应用没法再弹一次授权框，只能引路
                Button("打开系统通知设置") { permission.openSystemSettings() }
                    .controlSize(.small)
            }
            if let error = permission.lastDeliveryError {
                Text("最近一次通知发送失败：\(error)")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
