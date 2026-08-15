import SwiftUI
import AppKit

/// 右栏：会话/邮件详情。
///
/// 正文和工具栏都在 `ThreadDetailPane` 里（独立窗口用的是同一个），
/// 这里只管主窗口特有的部分：跟着中栏选择走、多选时的叠加卡片、删除交给列表执行。
struct MessageDetailView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mailStore: MailStore
    @StateObject private var model = MessageDetailModel()
    /// 全局设置：是否按会话显示邮件。关闭时右栏只展示选中的那一封。
    @AppStorage(SettingsKey.conversationView) private var conversationView = false
    /// 叠加卡片是否在场。多选一开就为 true；退出多选时不立刻撤，
    /// 等卡片飞回列表再由 `onLeaveFinished` 关掉。
    @State private var stackVisible = false

    var body: some View {
        // 叠加卡片盖在单选内容之上，而不是跟它二选一：退出多选时卡片要一边飞回
        // 列表，正文一边在底下淡进来，两者得同时在场。
        //
        // 容器必须是 ZStack 这样的实体容器，不能用 Group——Group 是透明的，
        // 加在它上面的 .animation 会被分发给每个分支各自持有，分支之间切换时
        // 拿不到动画，卡片的退场转场根本不会播。
        ZStack {
            Color.clear
            if !isMultiSelection {
                singleContent
            }
            if stackVisible {
                StackedSelectionView(
                    infos: appState.selectedInfos,
                    total: appState.selectedThreads.count,
                    isLeaving: !isMultiSelection,
                    onLeaveFinished: { if !isMultiSelection { stackVisible = false } }
                )
            }
        }
        // 只认「是不是多选」：单选之间来回切不该被卷进转场（正文是 WebView，淡入淡出会闪）。
        .animation(.easeInOut(duration: 0.3), value: isMultiSelection)
        .onAppear { stackVisible = isMultiSelection }
        // 退出多选时不在这儿撤掉卡片：先让它们飞回列表，飞完了才由回调关掉。
        .onChange(of: isMultiSelection) { _, multi in if multi { stackVisible = true } }
        .task(id: taskKey) { await reload() }
        // 池子里这串会话多了邮件（同步拿回来的新回复）才需要重取正文。
        // 必须连 threadID 一起比：只比条数的话，从一封单邮件切到一串多邮件会话
        // 也会被当成「来了新回复」，于是每次切回来都白拉一遍整串正文和内联图。
        .onChange(of: threadMessageCount) { old, new in
            guard old.threadID == new.threadID, old.count > 0, new.count > old.count else { return }
            Task { await model.reloadBody() }
        }
    }

    /// 删除交给中栏列表执行：它会把行移除并自动选中下一封。
    private func requestTrash() {
        guard let account = model.account, let id = model.threadID else { return }
        appState.requestTrash(account: account, id: id)
    }

    private var isMultiSelection: Bool { appState.selectedThreads.count > 1 }

    /// 非多选时右栏的内容：空状态、加载失败、加载中、正文。
    @ViewBuilder
    private var singleContent: some View {
        if appState.selectedThreads.isEmpty {
            ContentUnavailableView("未选择邮件", systemImage: "envelope")
        } else if let error = model.loadError, model.messages.isEmpty {
            ContentUnavailableView {
                Label("加载失败", systemImage: "exclamationmark.triangle")
            } description: { Text(error) }
        } else if model.isLoading && model.messages.isEmpty {
            ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ThreadDetailPane(model: model, onTrash: requestTrash)
        }
    }

    private var taskKey: String {
        "\(appState.singleSelection?.accountID ?? "")|\(appState.singleSelection?.threadID ?? "")|\(conversationView)"
    }

    /// 「当前这串会话在池子里有几封」。带上会话 id，换了会话就不是同一个计数了。
    private struct ThreadMessageCount: Equatable {
        let threadID: String
        let count: Int
    }

    private var threadMessageCount: ThreadMessageCount {
        ThreadMessageCount(threadID: model.threadID ?? "", count: model.messageIDs.count)
    }

    private func reload() async {
        guard let selected = appState.singleSelection else { return }
        model.bind(to: mailStore)
        // 正文不可变：缓存有就直接显示，没有才拉一次。
        await model.open(account: selected.accountID, threadID: selected.threadID,
                         conversation: conversationView)
        // 打开即标记已读（改的是池子里的标签，列表跟着一起变）
        await model.markReadOnOpenIfNeeded()
    }
}

/// 一封邮件的正文区：远程内容提示 + 正文 + 附件。
///
/// 单拎出来是因为它有两个去处：主窗口右栏的可折叠卡片里，和双击弹出的独立窗口里
/// （那边没有卡片外框，正文直接铺满）。远程内容那套开关也就只有一份。
struct MessageBodySection: View {
    let message: RenderedMessage
    let account: String

    @State private var webHeight: CGFloat
    /// 用户在本封邮件里手动点击「加载远程内容」后置为 true。
    @State private var showRemote = false
    /// 全局设置：是否默认加载远程内容。默认关闭。
    @AppStorage(SettingsKey.loadRemoteContentByDefault) private var loadRemoteByDefault = false

    init(message: RenderedMessage, account: String) {
        self.message = message
        self.account = account
        // 用上次量到的高度起步，正文一出现就是对的尺寸，不会先塌成一条再撑开
        _webHeight = State(initialValue: MessageBodyLayout.height(for: message.id))
    }

    /// 本封邮件最终是否加载远程内容：全局默认开启，或用户手动加载过。
    private var remoteEnabled: Bool { loadRemoteByDefault || showRemote }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsRemoteBanner {
                remoteBanner
            }
            MessageWebView(html: message.bodyHTML, blockRemote: !remoteEnabled,
                           messageID: message.id, height: $webHeight)
                .frame(height: webHeight)
            if !message.attachments.isEmpty {
                attachmentsView
            }
        }
    }

    private var showsRemoteBanner: Bool {
        // 仅在实际处于阻止状态、且正文含 http(s) 资源引用时，提示可加载远程内容。
        guard !remoteEnabled else { return false }
        return message.bodyHTML.contains("http://") || message.bodyHTML.contains("https://")
    }

    private var remoteBanner: some View {
        HStack {
            Image(systemName: "eye.slash")
            Text("已阻止远程内容以保护隐私")
                .font(.caption)
            Spacer()
            Button("加载远程内容") { showRemote = true }
                .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
    }

    private var attachmentsView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("附件（\(message.attachments.count)）").font(.caption).foregroundStyle(.secondary)
            ForEach(message.attachments) { att in
                AttachmentChip(attachment: att, account: account)
            }
        }
        .padding(.top, 4)
    }
}

/// 单封邮件卡片：可折叠。折叠时只显示头部摘要；展开时显示正文（WKWebView）与附件。
struct MessageCard: View {
    let message: RenderedMessage
    let account: String
    let isExpanded: Bool
    /// 未读状态来自池子，不存在卡片自己身上。
    let isUnread: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().padding(.horizontal, 12)
                MessageBodySection(message: message, account: account)
                    .padding(12)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isExpanded ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08),
                        lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    /// 头部：始终显示，点击切换展开/折叠。
    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if isUnread {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    }
                    Text(message.fromName).fontWeight(.semibold)
                    if isExpanded {
                        Text(message.fromEmail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(message.dateText).font(.caption).foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption2).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                if isExpanded {
                    if !message.to.isEmpty {
                        Text("收件人：\(message.to)")
                            .font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    Text(message.snippet ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    /// 发件人头像配色同样由地址稳定推导，理由见 `StableHash`。
    private var avatar: some View {
        Circle()
            .fill(Color(hue: Double(StableHash.index(message.fromEmail, upperBound: 360)) / 360,
                        saturation: 0.5, brightness: 0.85))
            .frame(width: 32, height: 32)
            .overlay(Text(String(message.fromName.first ?? "?").uppercased())
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
    }
}

/// 单个附件行：点击下载到用户选择的位置。
struct AttachmentChip: View {
    let attachment: Attachment
    let account: String
    @State private var isDownloading = false
    @State private var errorText: String?

    var body: some View {
        Button {
            download()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc")
                VStack(alignment: .leading, spacing: 0) {
                    Text(attachment.filename).lineLimit(1)
                    Text(attachment.sizeText).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .padding(8)
            .frame(maxWidth: 320, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        }
        .buttonStyle(.plain)
        .help(errorText ?? "点击下载")
    }

    private func download() {
        guard !isDownloading else { return }
        // 用系统保存面板让用户确认位置（即用户对下载的显式确认）
        let panel = NSSavePanel()
        panel.nameFieldStringValue = attachment.filename
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isDownloading = true
        errorText = nil
        Task {
            do {
                let data = try await GmailAPI(account: account)
                    .getAttachment(messageID: attachment.messageID, attachmentId: attachment.attachmentId)
                // 写盘挪出主线程：几十 MB 的附件在主线程上写，界面会整个僵住
                try await Task.detached { try data.write(to: url) }.value
                isDownloading = false
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isDownloading = false
            }
        }
    }
}
