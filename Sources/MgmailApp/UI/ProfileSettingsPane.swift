import SwiftUI

/// 设置窗口的「分组」页：为每个账号指定所属分组（互斥，一个账号只能属于一个分组）。
struct ProfileSettingsPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("每个账号只能属于一个分组。未分组的账号只在未选中任何分组时可见。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.accounts.isEmpty {
                ContentUnavailableView("暂无账号", systemImage: "person.crop.circle.badge.plus")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(appState.accounts) { account in
                            assignRow(account)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Divider()

            HStack {
                Button {
                    appState.addProfile(name: "新分组")
                } label: {
                    Label("新建分组", systemImage: "plus")
                }
                Spacer()
                if !appState.ungroupedAccounts.isEmpty {
                    Text("\(appState.ungroupedAccounts.count) 个账号未分组")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }

    /// 单个账号一行：左侧头像与邮箱，右侧分组下拉。
    private func assignRow(_ account: Account) -> some View {
        HStack(spacing: 12) {
            AccountAvatar(account: account, size: 28, reloadToken: appState.avatarReloadToken)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.displayName).font(.callout)
                Text(account.email).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: Binding(
                get: { appState.profileID(ofAccount: account.email) ?? "" },
                set: { appState.assignAccount(account.email, toProfile: $0.isEmpty ? nil : $0) }
            )) {
                Text("未分组").tag("")
                ForEach(appState.profiles) { profile in
                    Text(profile.name).tag(profile.id)
                }
            }
            .labelsHidden()
            .frame(width: 130)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }
}
