import SwiftUI

/// 设置 → 更新。
struct UpdateSettingsPane: View {
    @ObservedObject private var checker = UpdateChecker.shared
    @AppStorage(SettingsKey.updateAutoCheck) private var autoCheck = true
    @AppStorage(SettingsKey.updateChannel) private var channel = UpdateChannel.stable.rawValue

    var body: some View {
        Form {
            Section {
                LabeledContent("当前版本") {
                    Text(versionText)
                        .foregroundStyle(.secondary)
                }
                if UpdateChecker.isAvailable {
                    Toggle("自动检查更新", isOn: $autoCheck)
                    Picker("更新渠道", selection: $channel) {
                        ForEach(UpdateChannel.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .onChange(of: channel) { _, _ in
                        // 换了渠道，上一次的结论就不作数了
                        checker.reset()
                    }
                    Text(currentChannel.detail + " 更新来自 GitHub Release（athurg/mgmail），每小时对一次版本号。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if AppVersion.current == nil {
                    Text("直接 swift run 跑起来的进程没有 .app 包，没法替换自己。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("这是本机打包的开发包（Mgmail Dev），不参与自动更新：换成正式包就不是它自己了。正式包由 Scripts/package_dist.sh 或 GitHub Release 提供。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("版本")
            }

            if UpdateChecker.isAvailable {
                Section {
                    status
                } header: {
                    Text("检查更新")
                } footer: {
                    if let at = checker.lastCheckedAt {
                        Text("上次检查：\(DateText.messageHeader(at))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var versionText: String {
        guard let version = AppVersion.current else { return "未打包（swift run）" }
        return AppFlavor.current == .dev ? "\(version.fullText) · 开发包" : version.fullText
    }

    private var currentChannel: UpdateChannel {
        UpdateChannel(rawValue: channel) ?? .stable
    }

    @ViewBuilder
    private var status: some View {
        switch checker.phase {
        case .idle:
            HStack {
                Text("还没检查过。").foregroundStyle(.secondary)
                Spacer()
                Button("立即检查") { Task { await checker.check() } }
            }
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("正在检查…").foregroundStyle(.secondary)
            }
        case .upToDate:
            HStack {
                Text("已是最新版本。").foregroundStyle(.secondary)
                Spacer()
                Button("再查一次") { Task { await checker.check() } }
            }
        case .available(let manifest):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("有新版本：\(manifest.appVersion.fullText)")
                    Spacer()
                    Button("跳过此版本") { checker.skip() }
                    Button("下载并安装") { Task { await checker.download() } }
                        .keyboardShortcut(.defaultAction)
                }
                notes(manifest)
            }
        case .downloading(let manifest, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                Text("正在下载 \(manifest.appVersion.description)（\(sizeText(manifest.size))）…")
                ProgressView(value: fraction)
            }
        case .ready(let manifest, _):
            HStack {
                Text("\(manifest.appVersion.description) 已下载好，重新启动即完成安装。")
                Spacer()
                Button("重新启动") { checker.installAndRelaunch() }
                    .keyboardShortcut(.defaultAction)
            }
        case .failed(let text):
            VStack(alignment: .leading, spacing: 6) {
                Label(text, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("重试") {
                        checker.reset()
                        Task { await checker.check() }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func notes(_ manifest: UpdateManifest) -> some View {
        if let notes = manifest.notes, !notes.isEmpty {
            ScrollView {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 120)
        }
    }

    private func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
