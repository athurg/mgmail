import SwiftUI

/// 撰写窗口。每开一封就是一个独立窗口，互不打扰。
struct ComposeView: View {
    let composeID: UUID

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var mailStore: MailStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model: ComposeModel
    /// 抄送、密送默认收起——大多数信用不上，摊开只会挤占正文。
    @State private var showsCopyFields = false

    init(composeID: UUID) {
        self.composeID = composeID
        // 种子在开窗前就登记好了；万一没有（比如系统恢复窗口时），退化成一封空白新邮件
        let seed = ComposeStore.shared.seed(composeID)
            ?? ComposeStore.Seed(kind: .new, mail: OutgoingMail(fromName: "", fromEmail: ""))
        _model = StateObject(wrappedValue: ComposeModel(seed: seed))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TextEditor(text: $model.mail.body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if !model.mail.attachments.isEmpty || model.isFetchingAttachments
                || model.attachmentNotice != nil {
                Divider()
                attachmentBar
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle(title)
        .toolbar { toolbarItems }
        .alert("发送失败", isPresented: Binding(
            get: { model.errorText != nil }, set: { if !$0 { model.errorText = nil } }
        )) { Button("好", role: .cancel) {} } message: { Text(model.errorText ?? "") }
        .onChange(of: model.didSend) { _, sent in if sent { close() } }
        // 转发带过来的原件附件在窗口出现之后才取，免得开窗被几 MB 的下载卡住
        .task { await model.loadPendingAttachments() }
        .onDisappear { ComposeStore.shared.discard(composeID) }
    }

    private var title: String {
        let subject = model.mail.subject.trimmingCharacters(in: .whitespaces)
        return subject.isEmpty ? model.kind.windowTitle : subject
    }

    // MARK: - 头部字段

    private var header: some View {
        VStack(spacing: 0) {
            fieldRow("发件人") { senderPicker }
            Divider()
            fieldRow("收件人") {
                HStack(spacing: 6) {
                    TextField("", text: $model.mail.to, prompt: Text("多个地址用逗号隔开"))
                        .textFieldStyle(.plain)
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { showsCopyFields.toggle() }
                    } label: {
                        Image(systemName: showsCopyFields ? "chevron.up" : "chevron.down")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help(showsCopyFields ? "收起抄送、密送" : "抄送、密送")
                }
            }
            if showsCopyFields {
                Divider()
                fieldRow("抄送") {
                    TextField("", text: $model.mail.cc).textFieldStyle(.plain)
                }
                Divider()
                fieldRow("密送") {
                    TextField("", text: $model.mail.bcc).textFieldStyle(.plain)
                }
            }
            Divider()
            fieldRow("主题") {
                TextField("", text: $model.mail.subject).textFieldStyle(.plain)
            }
        }
    }

    private func fieldRow<Content: View>(_ label: String,
                                         @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
            content()
        }
        // 行内容一律靠左：发件人那行是个 fixedSize 的 Picker，行里没有能撑开的
        // 东西，不定死对齐的话整行会被 HStack 居中，和上下几行对不上。
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    /// 多账户时可以换发件人；只有一个账户就直接显示，不摆一个点不动的菜单。
    @ViewBuilder
    private var senderPicker: some View {
        let accounts = appState.activeAccounts
        if accounts.count > 1 {
            Picker("", selection: Binding(
                get: { model.mail.fromEmail },
                set: { email in
                    guard let account = accounts.first(where: { $0.email == email }) else { return }
                    model.mail.fromEmail = account.email
                    model.mail.fromName = account.displayName
                }
            )) {
                ForEach(accounts) { account in
                    Text("\(account.displayName) <\(account.email)>").tag(account.email)
                }
            }
            .labelsHidden()
            .fixedSize()
        } else {
            Text(model.mail.fromEmail).font(.callout)
            Spacer()
        }
    }

    // MARK: - 附件

    private var attachmentBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if model.isFetchingAttachments {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在取回原件附件…").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                }
                if let notice = model.attachmentNotice {
                    Label(notice, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .padding(.horizontal, 8)
                }
                ForEach(model.mail.attachments) { attachment in
                    HStack(spacing: 6) {
                        Image(systemName: "doc")
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.filename).lineLimit(1)
                            Text(attachment.sizeText).font(.caption2).foregroundStyle(.secondary)
                        }
                        Button { model.remove(attachment) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12)))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(height: 56)
        .overlay(alignment: .trailing) {
            if model.isOverAttachmentLimit {
                Label("附件超过 \(ByteCountFormatter.string(fromByteCount: Int64(ComposeModel.attachmentLimit), countStyle: .file))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.trailing, 12)
                    .background(.background)
            }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem {
            Button { model.pickAttachments() } label: {
                Image(systemName: "paperclip")
            }.help("添加附件")
        }
        ToolbarItem {
            Button {
                Task { await model.saveDraft(labels: labelStore, mail: mailStore) }
            } label: {
                Image(systemName: "tray.and.arrow.down")
            }.help("存草稿").disabled(model.isBusy)
        }
        ToolbarItem {
            Button {
                Task { await model.send(labels: labelStore, mail: mailStore) }
            } label: {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .help("发送（⌘↩）")
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canSend)
        }
    }

    private func close() {
        ComposeStore.shared.discard(composeID)
        dismiss()
    }
}
