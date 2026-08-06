import SwiftUI
import AppKit

/// 右栏：会话/邮件详情。
struct MessageDetailView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mailStore: MailStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = MessageDetailModel()
    @State private var showLabelPopover = false
    @State private var actionError: String?
    /// 当前展开的邮件 id 集合（会话里其余邮件折叠）。
    @State private var expanded: Set<String> = []
    /// 上次据以计算默认展开的消息 id 集合；用于避免联网刷新后重复重置、覆盖用户手动展开。
    @State private var expansionBasis: Set<String> = []
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
        .toolbar { if appState.singleSelection != nil && !model.messages.isEmpty { toolbarItems } }
        .alert("操作失败", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(actionError ?? "") }
        .task(id: taskKey) { await reload() }
        // 池子里这串会话多了邮件（同步拿回来的新回复）才需要重取正文。
        // 必须连 threadID 一起比：只比条数的话，从一封单邮件切到一串多邮件会话
        // 也会被当成「来了新回复」，于是每次切回来都白拉一遍整串正文和内联图。
        .onChange(of: threadMessageCount) { old, new in
            guard old.threadID == new.threadID, old.count > 0, new.count > old.count else { return }
            Task {
                await model.reloadBody()
                applyDefaultExpansion()
            }
        }
    }

    /// 工具栏分两组：① 邮件操作（归档、已读未读、星标、删除）② 标签。
    /// 用 ControlGroup 让组内按钮连成一体，组与组之间才有明显的间隔。
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem {
            ControlGroup {
                Button { compose(.reply(all: false)) } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                }.help("回复（⌘R）").keyboardShortcut("r", modifiers: .command)

                Button { compose(.reply(all: true)) } label: {
                    Image(systemName: "arrowshape.turn.up.left.2")
                }.help("全部回复（⇧⌘R）").keyboardShortcut("r", modifiers: [.command, .shift])

                Button { compose(.forward) } label: {
                    Image(systemName: "arrowshape.turn.up.right")
                }.help("转发（⇧⌘F）").keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }

        ToolbarItem {
            ControlGroup {
                Button {
                    run { try await model.archive() }
                } label: {
                    Image(systemName: "archivebox")
                }.help("归档（移出收件箱）").disabled(!model.isInInbox)

                Button {
                    let unread = !model.isUnread
                    run { try await model.setUnread(unread) }
                } label: {
                    Image(systemName: model.isUnread ? "envelope.badge" : "envelope.open")
                }.help(model.isUnread ? "标记为已读" : "标记为未读")

                Button {
                    run { try await model.toggleStar() }
                } label: {
                    Image(systemName: model.isStarred ? "star.fill" : "star")
                        .foregroundStyle(model.isStarred ? .yellow : .secondary)
                }.help(model.isStarred ? "取消星标" : "加星标")

                Button(role: .destructive) { requestTrash() } label: {
                    Image(systemName: "trash")
                }.help("删除（移入废纸篓）")
            }
        }

        ToolbarItem {
            Button { showLabelPopover.toggle() } label: {
                Image(systemName: model.hasUserLabels ? "tag.fill" : "tag")
            }.help("标签")
            .popover(isPresented: $showLabelPopover) {
                LabelEditorView(account: model.account ?? "", detail: model,
                                onClose: { showLabelPopover = false })
            }
        }
    }

    /// 开一个撰写窗口回复或转发。
    ///
    /// 回复的是会话里**最后一封**：一串会话里用户想接的总是最新的那条，
    /// 而不是最早那条。转发同理。
    private func compose(_ kind: ComposeKind) {
        guard let message = model.messages.last,
              let selected = appState.singleSelection,
              let account = appState.activeAccounts.first(where: { $0.id == selected.accountID })
        else { return }

        let id: UUID
        switch kind {
        case .reply(let all):
            id = ComposeStore.shared.reply(to: message, account: account,
                                           threadID: selected.threadID, all: all,
                                           quotedBody: MailQuote.reply(to: message))
        case .forward:
            id = ComposeStore.shared.forward(message, account: account,
                                             sourceAccount: selected.accountID,
                                             quotedBody: MailQuote.forward(message))
        case .new:
            id = ComposeStore.shared.newMail(from: account)
        }
        openWindow(id: ComposeWindow.id, value: id)
    }

    /// 删除交给中栏列表执行：它会把行移除并自动选中下一封。
    private func requestTrash() {
        guard let account = model.account, let id = model.threadID else { return }
        appState.requestTrash(account: account, id: id)
    }

    /// 执行一个修改操作。
    ///
    /// 不需要通知任何人：改的是池子里的标签，列表看的是同一份数据，自己就更新了。
    private func run(_ block: @escaping () async throws -> Void) {
        Task {
            do {
                try await block()
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
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
            content
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

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.subject)
                    .font(.title2).bold()
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding([.horizontal, .top])

                ForEach(model.messages) { message in
                    MessageCard(
                        message: message,
                        account: model.account ?? "",
                        isExpanded: expanded.contains(message.id),
                        isUnread: model.isUnread(message.id),
                        onToggle: { toggle(message.id) }
                    )
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// 切换单封邮件的展开/折叠。正文早就在手里了，纯本地。
    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    /// 会话加载后设定默认展开：多封时展开未读邮件；若全已读，只展开最新一封；单封则直接展开。
    /// 仅当消息 id 集合相较上次发生变化时才重新计算，避免覆盖用户已手动调整的展开状态。
    private func applyDefaultExpansion() {
        let msgs = model.messages
        guard !msgs.isEmpty else { expanded = []; expansionBasis = []; return }
        let ids = Set(msgs.map(\.id))
        guard ids != expansionBasis else { return }
        expansionBasis = ids
        if msgs.count == 1 { expanded = [msgs[0].id]; return }
        let unread = msgs.filter { model.isUnread($0.id) }.map(\.id)
        expanded = unread.isEmpty ? Set([msgs.last!.id]) : Set(unread)
    }

    private func reload() async {
        guard let selected = appState.singleSelection else { return }
        expansionBasis = []
        model.bind(to: mailStore)
        // 正文不可变：缓存有就直接显示，没有才拉一次。
        await model.open(account: selected.accountID, threadID: selected.threadID,
                         conversation: conversationView)
        applyDefaultExpansion()
        // 打开即标记已读（改的是池子里的标签，列表跟着一起变）
        await model.markReadOnOpenIfNeeded()
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

    @State private var webHeight: CGFloat

    init(message: RenderedMessage, account: String, isExpanded: Bool,
         isUnread: Bool, onToggle: @escaping () -> Void) {
        self.message = message
        self.account = account
        self.isExpanded = isExpanded
        self.isUnread = isUnread
        self.onToggle = onToggle
        // 用上次量到的高度起步，正文一出现就是对的尺寸，不会先塌成一条再撑开
        _webHeight = State(initialValue: MessageBodyLayout.height(for: message.id))
    }
    /// 用户在本封邮件里手动点击「加载远程内容」后置为 true。
    @State private var showRemote = false
    /// 全局设置：是否默认加载远程内容。默认关闭。
    @AppStorage(SettingsKey.loadRemoteContentByDefault) private var loadRemoteByDefault = false

    /// 本封邮件最终是否加载远程内容：全局默认开启，或用户手动加载过。
    private var remoteEnabled: Bool { loadRemoteByDefault || showRemote }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().padding(.horizontal, 12)
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
