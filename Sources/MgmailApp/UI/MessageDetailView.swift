import SwiftUI
import AppKit

/// 右栏：会话/邮件详情。
struct MessageDetailView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = MessageDetailModel()
    @State private var showLabelPopover = false
    @State private var actionError: String?
    /// 当前展开的邮件 id 集合（会话里其余邮件折叠）。
    @State private var expanded: Set<String> = []

    var body: some View {
        Group {
            if appState.selectedThreads.isEmpty {
                ContentUnavailableView("未选择邮件", systemImage: "envelope")
            } else if appState.selectedThreads.count > 1 {
                StackedSelectionView(infos: appState.selectedInfos, total: appState.selectedThreads.count)
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
        .toolbar { if appState.singleSelection != nil && !model.messages.isEmpty { toolbarItems } }
        .alert("操作失败", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(actionError ?? "") }
        .task(id: taskKey) { await reload() }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup {
            Button { run { try await model.toggleStar() } } label: {
                Image(systemName: model.isStarred ? "star.fill" : "star")
                    .foregroundStyle(model.isStarred ? .yellow : .secondary)
            }.help(model.isStarred ? "取消星标" : "加星标")

            Button { run { try await model.setUnread(!model.isUnread) } } label: {
                Image(systemName: model.isUnread ? "envelope.badge" : "envelope.open")
            }.help(model.isUnread ? "标记为已读" : "标记为未读")

            Button { run { try await model.archive() } } label: {
                Image(systemName: "archivebox")
            }.help("归档（移出收件箱）").disabled(!model.isInInbox)

            Button { showLabelPopover.toggle() } label: {
                Image(systemName: "tag")
            }.help("标签")
            .popover(isPresented: $showLabelPopover) {
                LabelEditorView(account: model.account ?? "", detail: model) {
                    broadcast()
                }
            }
        }
    }

    /// 执行一个修改操作，成功后广播变更。
    private func run(_ block: @escaping () async throws -> Void) {
        Task {
            do {
                try await block()
                broadcast()
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func broadcast() {
        if let account = model.account, let id = model.threadID {
            appState.threadDidChange(account: account, id: id)
        }
    }

    private var taskKey: String {
        "\(appState.singleSelection?.accountID ?? "")|\(appState.singleSelection?.threadID ?? "")"
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
                        onToggle: { toggle(message.id) }
                    )
                    .padding(.horizontal)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// 切换单封邮件的展开/折叠。
    private func toggle(_ id: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    /// 会话加载后设定默认展开：多封时展开未读邮件；若全已读，只展开最新一封；单封则直接展开。
    private func applyDefaultExpansion() {
        let msgs = model.messages
        guard !msgs.isEmpty else { expanded = []; return }
        if msgs.count == 1 { expanded = [msgs[0].id]; return }
        let unread = msgs.filter(\.isUnread).map(\.id)
        expanded = unread.isEmpty ? Set([msgs.last!.id]) : Set(unread)
    }

    private func reload() async {
        guard let selected = appState.singleSelection else { return }
        await model.load(account: selected.accountID, threadID: selected.threadID)
        // 在标记已读之前按未读状态决定默认展开
        applyDefaultExpansion()
        // 打开即标记已读，并广播让列表更新未读点
        if model.isUnread {
            await model.markReadOnOpenIfNeeded()
            broadcast()
        }
    }
}

/// 单封邮件卡片：可折叠。折叠时只显示头部摘要；展开时显示正文（WKWebView）与附件。
struct MessageCard: View {
    let message: RenderedMessage
    let account: String
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var webHeight: CGFloat = 40
    @State private var showRemote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 8) {
                    if showsRemoteBanner {
                        remoteBanner
                    }
                    MessageWebView(html: message.bodyHTML, blockRemote: !showRemote, height: $webHeight)
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
                    if message.isUnread {
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

    private var avatar: some View {
        Circle()
            .fill(Color(hue: Double(abs(message.fromEmail.hashValue) % 360) / 360, saturation: 0.5, brightness: 0.85))
            .frame(width: 32, height: 32)
            .overlay(Text(String(message.fromName.first ?? "?").uppercased())
                .font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
    }

    private var showsRemoteBanner: Bool {
        // 简单策略：正文里含 http(s) 资源引用时提示可加载远程内容
        !showRemote && (message.bodyHTML.contains("http://") || message.bodyHTML.contains("https://"))
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
                try data.write(to: url)
                isDownloading = false
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isDownloading = false
            }
        }
    }
}
