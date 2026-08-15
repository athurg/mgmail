import SwiftUI

enum MessageWindow {
    static let id = "message"
}

/// 双击列表行弹出的独立邮件窗口。
///
/// 它是个纯阅读窗口：没有标题栏文字、没有工具栏按钮（那些主窗口都有，
/// 这扇窗存在的意义就是把整块地方让给正文）。窗口本身用 `.hiddenTitleBar`，
/// 只剩左上角三个圆点浮在内容上面，主题就写在它们旁边——那条本来空着的
/// 标题栏高度里，正好装下一行主题，不用再单开一行。
///
/// 有自己的 `MessageDetailModel`：窗口开着的时候用户在主窗口翻别的邮件，
/// 这扇窗不该跟着变——独立出来就是为了钉住一封。
struct MessageWindowView: View {
    let target: SelectedThread

    @EnvironmentObject private var mailStore: MailStore
    @StateObject private var model = MessageDetailModel()
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
        // 标题栏是隐藏的，看不见这个标题；但「窗口」菜单和 Mission Control 里认它。
        .navigationTitle(model.subject.isEmpty ? "邮件" : model.subject)
        // 必须绑 target：SwiftUI 开第二扇窗时会把这个场景的视图连同它的 @StateObject
        // 一起复用，只把窗口值换掉——不带 id 的 .task 那时不会重跑，新窗口里显示的
        // 就还是上一封邮件。
        .task(id: target) { await load() }
    }

    /// 阅读区：主题、一条紧凑的信头，底下全是正文。
    ///
    /// 正文不做折叠：这扇窗一次只看一封（会话模式下是一串，那就一封接一封铺开），
    /// 用不着卡片外框和展开箭头去区分谁是谁——那些都是在列表和右栏里才需要的东西。
    private var reader: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 主题贴着安全区顶上排。标题栏藏了，但那块高度仍被系统留着给三个圆点，
                // 内容本来就是从圆点下面开始的，所以这里不用再往下推，也不用给左边让位。
                // 不开 textSelection——上面那条是窗口的拖动区，让它保持能拖，选文字去正文里选。
                Text(model.subject)
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 2)

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

    /// 一封邮件的信头：发件人、地址、时间、收件人。一行装得下就一行。
    private func sender(_ message: RenderedMessage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(message.fromName).fontWeight(.semibold)
                Text(message.fromEmail).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Text(message.dateText).foregroundStyle(.secondary)
            }
            if !message.to.isEmpty {
                Text("收件人：\(message.to)").foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(.caption)
        .textSelection(.enabled)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private func load() async {
        model.bind(to: mailStore)
        await model.open(account: target.accountID, threadID: target.threadID,
                         conversation: conversation)
        await model.markReadOnOpenIfNeeded()
    }
}
