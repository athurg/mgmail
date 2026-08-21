import SwiftUI

enum MessageWindow {
    static let id = "message"
}

/// 双击列表行弹出的独立邮件窗口。
///
/// 它以阅读为主：窗口用 `.hiddenTitleBar`，标题栏不写文字，正文一路铺到顶
/// （主题作为内容的第一行，不再单占一条标题）。标题栏那条高度也没浪费——
/// 左边是系统的三个圆点，右边挂一组读信时真正会用到的按钮（回信、归档、星标），
/// 两头都有东西，中间留白仍然是窗口的拖动区。
///
/// 按钮只挑读信这一路的：写信三件套加归档、已读未读、星标。列表相关的（删除后
/// 选中下一封）和标签面板留在主窗口——这扇窗只钉着一封信看，不承担整理邮箱的活。
///
/// 有自己的 `MessageDetailModel`：窗口开着的时候用户在主窗口翻别的邮件，
/// 这扇窗不该跟着变——独立出来就是为了钉住一封。
struct MessageWindowView: View {
    let target: SelectedThread

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var mailStore: MailStore
    @Environment(\.openWindow) private var openWindow
    @StateObject private var model = MessageDetailModel()
    /// 工具栏上那些操作失败时的提示文案。
    @State private var actionError: String?
    /// 鼠标在不在这扇窗里。标题栏那排按钮据此现身/隐去。
    @State private var pointerInside = false
    /// 开窗那一刻的显示方式。
    ///
    /// 不用 `@AppStorage` 跟着设置走：`target.threadID` 在会话模式下是 threadId、
    /// 否则是 messageId，窗口开着时用户去改设置，这扇窗手里的 id 就会被按错的语义去解释。
    /// 开窗时定下来，这一扇窗一辈子按它来。
    @State private var conversation = UserDefaults.standard.bool(forKey: SettingsKey.conversationView)

    var body: some View {
        Group {
            if let error = model.loadError, model.messages.isEmpty {
                ContentUnavailableView {
                    Label("加载失败", systemImage: "exclamationmark.triangle")
                } description: { Text(error) }
            } else if model.messages.isEmpty {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                reader
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        // 探针要盖到标题栏那条上去，所以得越过安全区，理由见 WindowHoverReporter
        .background(WindowHoverReporter(inside: $pointerInside).ignoresSafeArea())
        // 标题栏是隐藏的，看不见这个标题；但「窗口」菜单和 Mission Control 里认它。
        .navigationTitle(model.subject.isEmpty ? "邮件" : model.subject)
        // 邮件还没到手时不摆按钮：那时候按下去也没有对象可操作，摆着只是幌子。
        .toolbar { if !model.messages.isEmpty { toolbarItems } }
        .alert("操作失败", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(actionError ?? "") }
        // 必须绑 target：SwiftUI 开第二扇窗时会把这个场景的视图连同它的 @StateObject
        // 一起复用，只把窗口值换掉——不带 id 的 .task 那时不会重跑，新窗口里显示的
        // 就还是上一封邮件。
        .task(id: target) { await load() }
    }

    /// 标题栏右侧的按钮。
    ///
    /// 处置这封信的那两个常驻——读一封信最后总要处置它，它们该一直在手边。
    /// 一个是删除，一个随邮件所在处变脸（在收件箱是归档，在别处是移回收件箱）；
    /// 已经在废纸篓里的信没什么可再删的，那时只剩变脸的那一个。
    /// 其余的（写信三件套、已读未读、星标）鼠标进了这扇窗才淡入，挪开就淡掉：
    /// 平时标题栏干净，手伸过来工具才出现。快捷键（⌘R 等）不受影响，淡着也一直认。
    ///
    /// 常驻的那组排在最右：整排是右对齐的，悬停的按钮从左边插进来，
    /// 归档和删除的位置才不会被推着走。
    ///
    /// 是裸图标，不是 ControlGroup 那种胶囊：胶囊为了照顾自己的圆角，四周得留出
    /// 一圈余量，图标缩小了那圈余量却还在，看着就是几个小图标各自泡在一块白底里。
    ///
    /// 开头那个 Spacer 是把按钮推到右边用的：这扇窗没有标题文字，工具栏项会一路
    /// 挤到左边紧贴着三个圆点排，右半条标题栏照样空着——那正是要治的毛病。
    /// （`.primaryAction` 在没有标题的窗口上不管用，试过了。）
    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem { Spacer() }

        // 系统给工具栏项垫的那块玻璃底得摘掉：它是系统画的、不在视图树里，跟着
        // 按钮的 opacity 淡不走——图标淡掉了，标题栏右边还杵着一块空白圆角。
        if #available(macOS 26.0, *) {
            actionItem.sharedBackgroundVisibility(.hidden)
        } else {
            actionItem
        }
    }

    /// 按钮全都装在同一个 ToolbarItem 里，间距自己排：拆成几个 item 的话，
    /// 系统把它们塞进同一块背景、彼此不留空隙，组和组就分不出来了。
    private var actionItem: some ToolbarContent {
        ToolbarItem {
            HStack(spacing: 14) {
                Group {
                    Button { compose(.reply(all: false)) } label: {
                        Image(systemName: "arrowshape.turn.up.left")
                    }.help("回复（⌘R）").keyboardShortcut("r", modifiers: .command)

                    Button { compose(.reply(all: true)) } label: {
                        Image(systemName: "arrowshape.turn.up.left.2")
                    }.help("全部回复（⇧⌘R）").keyboardShortcut("r", modifiers: [.command, .shift])

                    Button { compose(.forward) } label: {
                        Image(systemName: "arrowshape.turn.up.right")
                    }.help("转发（⇧⌘F）").keyboardShortcut("f", modifiers: [.command, .shift])

                    Divider().frame(height: 13)

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

                    // 这条线属于淡入那一组：只剩常驻两个按钮时，它跟着一起收走
                    Divider().frame(height: 13)
                }
                .modifier(HoverRevealed(shown: pointerInside))

                // 已经在废纸篓里的就不摆删除了：再删一次只能是永久删除，这个应用不做。
                if model.placement.canTrash {
                    Button {
                        // 删完不关窗：信进了废纸篓照样能看、能移回收件箱，这个按钮自己会
                        // 退成只剩「移回收件箱」，人想反悔就在原地反悔——关掉窗反倒断了这条路。
                        run { try await model.trash() }
                    } label: {
                        Image(systemName: "trash")
                    }.help("删除（移入废纸篓）")
                }

                // 归档和移回收件箱是同一个按钮的两副面孔，见 ThreadDetailPane 里的同一处
                Button {
                    let placement = model.placement
                    run {
                        if placement.canArchive { try await model.archive() }
                        else { try await model.moveToInbox() }
                    }
                } label: {
                    Image(systemName: model.placement.moveIcon)
                }.help(model.placement.moveHelp)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            // 让最右那个按钮离窗口边角的距离，跟左边第一个圆点离边角的距离对上：
            // 系统默认留得比红绿灯那头少，右边显得贴边。这个数是照着实测补的差额，
            // 跟最右是哪个图标有关（照归档那个图标量的；换掉最右那个按钮得重新量一次）。
            .padding(.trailing, 15)
        }
    }

    /// 开一个撰写窗口回复或转发。规则见 `MessageComposeAction`（主窗口右栏用的是同一套）。
    private func compose(_ kind: ComposeKind) {
        guard let id = MessageComposeAction.windowValue(kind, model: model,
                                                        accounts: appState.accounts) else { return }
        openWindow(id: ComposeWindow.id, value: id)
    }

    /// 执行一个修改操作。改的是池子里的标签，主窗口的列表看的是同一份数据，自己就跟着变。
    private func run(_ block: @escaping () async throws -> Void) {
        Task {
            do {
                try await block()
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    /// 阅读区：主题、一条紧凑的信头，底下全是正文。
    ///
    /// 正文不做折叠：这扇窗一次只看一封（会话模式下是一串，那就一封接一封铺开），
    /// 用不着卡片外框和展开箭头去区分谁是谁——那些都是在列表和右栏里才需要的东西。
    private var reader: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 主题贴着安全区顶上排。工具栏那条高度是系统留的，内容本来就从它下面开始，
                // 这里不用再往下推，也不用给左边的三个圆点让位。
                Text(model.subject)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)

                ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                    // 一串会话里每封之间划一道线，单封时上面那条信头就够了，不用再分
                    if index > 0 {
                        Divider().padding(.top, 12)
                    }
                    sender(message)
                    MessageBodySection(message: message, account: model.account ?? "")
                        .padding(.horizontal, 16)
                }
            }
            .padding(.bottom, 16)
        }
    }

    /// 一封邮件的信头：发件人一行、收件人一行，时间跟着发件人那行靠右。
    ///
    /// 两行都带头衔，不能只给收件人挂「收件人」而让发件人裸着——那样两行左边就对不齐，
    /// 也让人一时读不出上面那行是谁。用 Grid 排：第一列由系统去取两个头衔的最大宽度，
    /// 名字和地址自然对齐成一竖条。
    private func sender(_ message: RenderedMessage) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
            GridRow {
                Text("发件人").foregroundStyle(.tertiary)
                HStack(spacing: 6) {
                    Text(message.fromName).fontWeight(.semibold)
                    Text(message.fromEmail).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(message.dateText).foregroundStyle(.secondary)
                }
            }
            // 收件人、抄送、密送——有内容的才有这一行，规则见 `RenderedMessage.recipientFields`。
            // 这扇窗是专门钉着一封信看的，抄送名单值得摊开，但也不能占掉半屏，所以封到三行。
            ForEach(message.recipientFields) { field in
                GridRow {
                    Text(field.label).foregroundStyle(.tertiary)
                    Text(field.value).foregroundStyle(.secondary).lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.caption)
        .textSelection(.enabled)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        // 信头是几段文字加空白，空白处默认不接鼠标；不补一块形状的话，
        // 右键点在名字之间的空当上什么也不会弹。
        .contentShape(Rectangle())
        // 和右栏卡片一样，原文入口挂在这封信自己的信头上
        .contextMenu {
            Button("查看原始邮件") {
                openWindow(id: RawSourceWindow.id,
                           value: RawSourceTarget(accountID: model.account ?? "",
                                                  messageID: message.id))
            }
        }
    }

    /// 一组悬停才现身的标题栏按钮该长什么样：裸图标、暗一号的颜色、淡入淡出。
    ///
    /// 淡掉的时候要一并挡掉点击：`opacity(0)` 的按钮在 SwiftUI 里照样接得住鼠标，
    /// 不挡的话标题栏上会留下几块看不见却按得动的地方。
    private struct HoverRevealed: ViewModifier {
        let shown: Bool

        func body(content: Content) -> some View {
            content
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .animation(.easeInOut(duration: 0.18), value: shown)
        }
    }

    private func load() async {
        model.bind(to: mailStore)
        await model.open(account: target.accountID, threadID: target.threadID,
                         conversation: conversation)
        model.markReadOnOpenIfNeeded()
    }
}
