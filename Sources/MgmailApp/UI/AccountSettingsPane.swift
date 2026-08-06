import SwiftUI

/// 设置窗口的「账号」页：改显示名、加备注、移除账号、添加账号。
struct AccountSettingsPane: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mailStore: MailStore
    @State private var pendingRemoval: Account?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if appState.accounts.isEmpty {
                ContentUnavailableView("暂无账号", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(appState.accounts) { account in
                            AccountRow(account: account) { pendingRemoval = account }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Divider()

            HStack {
                Button {
                    appState.addAccount()
                } label: {
                    Label(appState.isSigningIn ? "登录中…（点击可重新开始）" : "添加账号", systemImage: "plus")
                }
                .disabled(!appState.hasOAuthConfig)
                Spacer()
            }
        }
        .padding(20)
        .alert("移除账号", isPresented: Binding(
            get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
        )) {
            Button("取消", role: .cancel) { pendingRemoval = nil }
            Button("移除", role: .destructive) {
                if let account = pendingRemoval {
                    // 内存里的池子也要一并撤掉，否则账号没了邮件还留在聚合视图里
                    mailStore.drop(account: account.id)
                    appState.removeAccount(account)
                }
                pendingRemoval = nil
            }
        } message: {
            Text("将从 Mgmail 移除「\(pendingRemoval?.email ?? "")」并删除其本地登录凭据与缓存。此操作不影响你的 Gmail 账户本身。")
        }
    }
}

/// 单个账号的可编辑行。
private struct AccountRow: View {
    let account: Account
    var onRemove: () -> Void
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AccountAvatar(account: account, size: 36, reloadToken: appState.avatarReloadToken)

            VStack(alignment: .leading, spacing: 6) {
                Text(account.email).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("显示名").font(.caption).foregroundStyle(.secondary).frame(width: 42, alignment: .leading)
                    TextField("显示名", text: Binding(
                        get: { account.displayName },
                        set: { appState.setDisplayName($0, for: account.id) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
                HStack(spacing: 8) {
                    Text("备注").font(.caption).foregroundStyle(.secondary).frame(width: 42, alignment: .leading)
                    TextField("如：工作 / 个人 / 客服…", text: Binding(
                        get: { account.note },
                        set: { appState.setNote($0, for: account.id) }
                    ))
                    .textFieldStyle(.roundedBorder)
                }
            }

            VStack(spacing: 8) {
                Button { appState.addAccount() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("重新登录（更新头像/授权）")

                Button(role: .destructive) { onRemove() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("移除账号")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}
