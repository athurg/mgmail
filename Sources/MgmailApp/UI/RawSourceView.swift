import SwiftUI
import AppKit

enum RawSourceWindow {
    static let id = "raw-source"
}

/// 「查看原始邮件」窗口的目标：哪个账号的哪一封。
///
/// 一定是**某一封**，不是一串会话：原文是一封信一份，会话没有共同的原文。
struct RawSourceTarget: Hashable, Codable {
    let accountID: String
    let messageID: String
}

/// 原始邮件窗口：上面切「邮件头」和「完整原文」，工具栏管拷贝、存盘、查找。
///
/// 分两页看是因为两种用法本来就不同：查退信、查这封信打哪儿来、看 SPF/DKIM 过没过，
/// 眼睛只在头字段上，而头在原文里是折了行、编了码、埋在几十条 `Received` 中间的；
/// 真要一字不差地对，再翻到完整原文那页。
///
/// 原文不进缓存：正文缓存那套是给「天天要看」的东西准备的，原文是偶尔查一次的，
/// 每次现取反而省事——也保证看到的一定是服务器上现在的那份。
struct RawSourceView: View {
    let target: RawSourceTarget

    @EnvironmentObject private var mailStore: MailStore
    @StateObject private var finder = RawTextFinder()
    @State private var source: RawSource?
    @State private var loadError: String?
    @State private var page: Page = .headers
    /// 「已拷贝」那句提示还在不在。
    @State private var copiedAt: Date?

    private enum Page: Hashable {
        case headers, full
    }

    var body: some View {
        Group {
            if let loadError, source == nil {
                ContentUnavailableView {
                    Label("取不到原文", systemImage: "exclamationmark.triangle")
                } description: { Text(loadError) }
            } else if let source {
                content(source)
            } else {
                ProgressView("读取原文…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .navigationTitle(subject.isEmpty ? "原始邮件" : "原始邮件：\(subject)")
        .toolbar { if source != nil { toolbarItems } }
        .task(id: target) { await load() }
    }

    private func content(_ source: RawSource) -> some View {
        VStack(spacing: 0) {
            Picker("", selection: $page) {
                Text("邮件头（\(source.headers.count)）").tag(Page.headers)
                Text("完整原文").tag(Page.full)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)
            .padding(8)

            Divider()

            switch page {
            case .headers: headerList(source.headers)
            case .full: RawTextView(text: source.text, finder: finder)
            }

            Divider()
            footer(source)
        }
    }

    // MARK: - 邮件头

    private func headerList(_ headers: [RawHeader]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(headers) { header in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(header.name)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .frame(width: 132, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(header.value)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            // 编码过的头字段把原样也摆出来：解码是我们代劳的，
                            // 出了岔子（乱码、字符集不认）得能看见没解之前长什么样。
                            if header.isEncoded {
                                Text(header.raw)
                                    .foregroundStyle(.tertiary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.vertical, 5)
                    .padding(.horizontal, 12)
                    // 隔行底色：`Received` 一条能占三四行，没有底色分不清哪几行是一条
                    .background(header.id.isMultiple(of: 2) ? Color.clear
                                                            : Color.secondary.opacity(0.06))
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - 底栏 / 工具栏

    private func footer(_ source: RawSource) -> some View {
        HStack(spacing: 8) {
            Text(ByteCountFormatter.string(fromByteCount: Int64(source.byteCount), countStyle: .file))
            Text("·")
            Text("\(source.headers.count) 条头字段")
            Spacer()
            if let copiedAt, Date().timeIntervalSince(copiedAt) < 2 {
                Label("已拷贝", systemImage: "checkmark.circle")
                    .transition(.opacity)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem {
            Button { finder.showFindBar() } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("在原文中查找")
            // 查找栏是那块文本视图自己的，只有在完整原文那页才有东西可找
            .disabled(page != .full)
        }
        ToolbarItem {
            Button { copy() } label: {
                Image(systemName: "doc.on.doc")
            }.help(page == .full ? "拷贝完整原文" : "拷贝全部头字段")
        }
        ToolbarItem {
            Button { save() } label: {
                Image(systemName: "square.and.arrow.down")
            }.help("存为 .eml 文件")
        }
    }

    // MARK: - 动作

    /// 当前这一页的文字。拷贝按钮按页给不同的东西——在头那一页要的多半就是那几条头。
    private var copyText: String {
        guard let source else { return "" }
        switch page {
        case .full: return source.text
        case .headers:
            return source.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        withAnimation { copiedAt = Date() }
        // 提示自己退场：底栏那句话靠时间判断显不显示，得有人在两秒后再推它一下
        Task {
            try? await Task.sleep(for: .seconds(2.1))
            withAnimation { copiedAt = nil }
        }
    }

    /// 存成 .eml。写的是原始字节而不是屏幕上那份文本：文本是解码过的，
    /// 存出去的文件得能被别的邮件客户端原样打开。
    private func save() {
        guard let source else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = filename
        panel.allowedContentTypes = [.init(filenameExtension: "eml") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try source.data.write(to: url)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private var subject: String {
        mailStore.message(account: target.accountID, id: target.messageID)?.subject ?? ""
    }

    private var filename: String {
        let base = subject.isEmpty ? target.messageID : subject
        // 文件名里不能有斜杠和冒号（Finder 会把冒号显示成斜杠）
        let safe = base.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return String(safe.prefix(80)) + ".eml"
    }

    private func load() async {
        source = nil
        loadError = nil
        do {
            let data = try await GmailAPI(account: target.accountID).getRawMessage(id: target.messageID)
            source = RawSource.parse(data)
        } catch {
            guard !error.isCancellation else { return }
            loadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// 完整原文那一页：只读的 NSTextView。
///
/// 不用 `Text`：一封带附件的信原文能有好几 MB，SwiftUI 的 Text 要把它整个排版一遍，
/// 窗口能卡上好几秒。NSTextView 是按需排版的，顺带白拿了系统的查找栏和逐行选择。
private struct RawTextView: NSViewRepresentable {
    let text: String
    let finder: RawTextFinder

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isEditable = false
        textView.isRichText = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.string = text
        finder.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        if textView.string != text { textView.string = text }
        finder.textView = textView
    }
}

/// 工具栏上那个放大镜和文本视图之间的一根线。
///
/// ⌘F 在这扇窗里不归它管——那个快捷键被「编辑 → 搜索邮件」占着（那是搜邮件列表的），
/// 菜单的快捷键优先于视图，按下去到不了这里。所以查找栏得有个自己的按钮。
@MainActor
final class RawTextFinder: ObservableObject {
    weak var textView: NSTextView?

    func showFindBar() {
        guard let textView else { return }
        // 查找栏认的是第一响应者。用户可能一次都没点过正文，先把焦点给它。
        textView.window?.makeFirstResponder(textView)
        let action = NSMenuItem()
        action.tag = NSTextFinder.Action.showFindInterface.rawValue
        textView.performTextFinderAction(action)
    }
}
