import SwiftUI
import AppKit

/// 首次运行引导：指导用户创建 Google OAuth 客户端并放置 oauth_client.json。
struct SetupView: View {
    @EnvironmentObject private var appState: AppState

    private var clientPath: String { GoogleConfig.clientFileURL.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("配置 Gmail 访问权限").font(.title2).bold()
                    Text("Mgmail 通过 Gmail API 访问邮件，需要你自己的 Google OAuth 客户端。")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                step(1, "打开 Google Cloud Console，新建一个项目（如 Mgmail）。")
                step(2, "在「API 和服务」中启用 Gmail API。")
                step(3, "配置 OAuth 同意屏幕：User Type 选 External，添加 scope gmail.modify，并把你的 Gmail 地址加入 Test users。")
                step(4, "创建凭据 → OAuth 客户端 ID → 应用类型选「桌面应用」，下载 JSON。")
                step(5, "把下载的 JSON 重命名为 oauth_client.json，放到下面的目录：")
            }

            HStack(spacing: 8) {
                Text(clientPath)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                Button("打开目录") {
                    GoogleConfig.ensureSupportDirectory()
                    NSWorkspace.shared.open(GoogleConfig.supportDirectory)
                }
            }

            HStack {
                Link("打开 Google Cloud Console", destination: URL(string: "https://console.cloud.google.com/")!)
                Spacer()
                Button("我已放好文件，重新检测") {
                    appState.refreshConfigStatus()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)

            Text("提示：同意屏幕停留在「测试」状态时，Google 的 refresh token 约 7 天过期，届时需重新登录。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 560)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.caption).bold()
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Circle().fill(.tint))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
