import SwiftUI

/// 一串会话（或一封邮件）的正文与工具栏。
///
/// 主窗口右栏和双击弹出的独立窗口用的是同一个它：两边看到的正文、展开折叠、
/// 回复转发、标签面板都必须一模一样，抄两份迟早会长歪。
///
/// 两边唯一的差别是删除该怎么收场——主窗口要把行从列表里拿掉并自动选中下一封，
/// 独立窗口则是删完把自己关掉——所以删除由外面传进来。
struct ThreadDetailPane: View {
    @ObservedObject var model: MessageDetailModel
    /// 点了删除。主窗口转交给中栏列表，独立窗口自己删完关窗。
    let onTrash: () -> Void
    /// 操作按钮摆哪儿。主窗口的标题栏藏了，主题和按钮固定在面板头（参考 Telegram 的聊天头）；
    /// 独立阅读窗口有自己那套悬停才现身的标题栏按钮，正文里只把主题当第一行。
    var pinnedHeader = false

    @EnvironmentObject private var appState: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var showLabelPopover = false
    @State private var actionError: String?
    /// 当前展开的邮件 id 集合（会话里其余邮件折叠）。
    @State private var expanded: Set<String> = []
    /// 上次据以计算默认展开的消息 id 集合；用于避免联网刷新后重复重置、覆盖用户手动展开。
    @State private var expansionBasis: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            if pinnedHeader, !model.messages.isEmpty {
                panelHeader
            }
            messageList
        }
        .alert("操作失败", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(actionError ?? "") }
        // 会话换了、或者同步给这串会话添了新回复，都在这儿重新定默认展开。
        .onChange(of: model.messages.map(\.id), initial: true) { _, _ in applyDefaultExpansion() }
    }

    /// 面板头：主题在左，操作按钮在右，不随正文滚动。
    private var panelHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(model.subject)
                .font(.headline)
                .lineLimit(2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            actionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 操作按钮分两组：① 写信（回复/全部回复/转发）② 处置（归档/已读未读/星标/删除），末尾是标签。
    /// 裸图标加细分隔线，不用 ControlGroup 的胶囊——那圈余量在面板头里显得笨。
    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button { compose(.reply(all: false)) } label: {
                Image(systemName: "arrowshape.turn.up.left")
            }.help("回复（⌘R）").keyboardShortcut("r", modifiers: .command)

            Button { compose(.reply(all: true)) } label: {
                Image(systemName: "arrowshape.turn.up.left.2")
            }.help("全部回复（⇧⌘R）").keyboardShortcut("r", modifiers: [.command, .shift])

            Button { compose(.forward) } label: {
                Image(systemName: "arrowshape.turn.up.right")
            }.help("转发（⇧⌘F）").keyboardShortcut("f", modifiers: [.command, .shift])

            Divider().frame(height: 14)

            // 归档和移回收件箱是同一个按钮的两副面孔：邮件已经不在收件箱了，
            // 「归档」就没有意义，那个位置该换成把它送回去。
            Button {
                let placement = model.placement
                run {
                    if placement.canArchive { try await model.archive() }
                    else { try await model.moveToInbox() }
                }
            } label: {
                Image(systemName: model.placement.moveIcon)
            }.help(model.placement.moveHelp)

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

            // 已经在废纸篓里的就不摆删除了：再删一次只能是永久删除，这个应用不做。
            if model.placement.canTrash {
                Button(role: .destructive) { onTrash() } label: {
                    Image(systemName: "trash")
                }.help("删除（移入废纸篓）")
            }

            Divider().frame(height: 14)

            Button { showLabelPopover.toggle() } label: {
                Image(systemName: model.hasUserLabels ? "tag.fill" : "tag")
            }.help("标签")
            .popover(isPresented: $showLabelPopover) {
                LabelEditorView(account: model.account ?? "", detail: model,
                                onClose: { showLabelPopover = false })
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
        .fixedSize()
    }

    private var messageList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                // 面板头已经写了主题的，正文里不再重复一遍
                if !pinnedHeader {
                    Text(model.subject)
                        .font(.title2).bold()
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding([.horizontal, .top])
                }

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

    /// 开一个撰写窗口回复或转发。规则见 `MessageComposeAction`（独立窗口用的是同一套）。
    private func compose(_ kind: ComposeKind) {
        guard let id = MessageComposeAction.windowValue(kind, model: model,
                                                        accounts: appState.accounts) else { return }
        openWindow(id: ComposeWindow.id, value: id)
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
}
