import SwiftUI
import AppKit

/// 一个撰写窗口的状态与动作。
@MainActor
final class ComposeModel: ObservableObject {
    /// Gmail 的 JSON 简单上传对整封报文的上限是 5MB。base64 会把附件撑大约 1/3，
    /// 所以按原始字节 3.5MB 拦，留出编码和头部的余量。
    static let attachmentLimit = 3_500_000

    @Published var mail: OutgoingMail
    @Published var isBusy = false
    @Published var errorText: String?
    /// 发送成功后置位，窗口据此自动关闭。
    @Published var didSend = false
    /// 转发的原件附件还在取回中（附件条上显示进度，发送按钮暂时压住）。
    @Published private(set) var isFetchingAttachments = false
    /// 附件相关的提示（哪几个没取回来）。就近显示在附件条上，不弹窗打断撰写。
    @Published var attachmentNotice: String?

    let kind: ComposeKind

    init(seed: ComposeStore.Seed) {
        self.kind = seed.kind
        self.mail = seed.mail
    }

    /// 附件还没取全就发出去，等于转发了一封缺附件的信，所以要等。
    var canSend: Bool { mail.canSend && !isBusy && !isFetchingAttachments }

    // MARK: - 转发：取回原件附件

    /// 把 `pendingAttachments` 逐个下载成真正的附件。窗口出现后调一次。
    ///
    /// 一个失败不牵连其余：能带走几个是几个，缺哪个明说，由用户决定要不要照发。
    func loadPendingAttachments() async {
        let pending = mail.pendingAttachments
        guard !pending.isEmpty, let account = mail.attachmentSourceAccount else { return }
        // 清空在前：窗口重建时不会重复取一遍
        mail.pendingAttachments = []
        isFetchingAttachments = true
        defer { isFetchingAttachments = false }

        let api = GmailAPI(account: account)
        var failed: [String] = []
        for item in pending {
            do {
                let data = try await api.getAttachment(messageID: item.messageID,
                                                       attachmentId: item.attachmentId)
                mail.attachments.append(OutgoingAttachment(filename: item.filename,
                                                           mimeType: item.mimeType,
                                                           data: data))
            } catch {
                failed.append(item.filename)
            }
        }
        if !failed.isEmpty {
            attachmentNotice = "有 \(failed.count) 个附件没取回来（\(failed.joined(separator: "、"))），"
                + "可手动添加后再发"
        }
    }

    var isOverAttachmentLimit: Bool { mail.attachmentsSize > Self.attachmentLimit }

    var attachmentsSizeText: String {
        ByteCountFormatter.string(fromByteCount: Int64(mail.attachmentsSize), countStyle: .file)
    }

    // MARK: - 附件

    func pickAttachments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "添加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            do {
                mail.attachments.append(try OutgoingAttachment(url: url))
            } catch {
                errorText = "读不了「\(url.lastPathComponent)」：\(error.localizedDescription)"
            }
        }
    }

    func remove(_ attachment: OutgoingAttachment) {
        mail.attachments.removeAll { $0.id == attachment.id }
    }

    // MARK: - 发送 / 存草稿

    /// 发送。成功后置 `didSend`，窗口自己关掉。
    ///
    /// 发完顺手同步一次账号：Gmail 会把这封放进「已发送」，而本地池子是靠
    /// history 增量更新的，不主动催一下要等到下一次定时刷新才看得见。
    func send(labels: LabelStore, mail store: MailStore) async {
        guard canSend else { return }
        guard !isOverAttachmentLimit else {
            errorText = "附件太大（\(attachmentsSizeText)），上限 \(ByteCountFormatter.string(fromByteCount: Int64(Self.attachmentLimit), countStyle: .file))。"
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let raw = MimeBuilder.build(mail)
            try await GmailAPI(account: mail.fromEmail).sendMessage(raw: raw, threadID: mail.threadID)
            didSend = true
            await MailRefresh.account(mail.fromEmail, labels: labels, mail: store, colors: false)
        } catch {
            errorText = message(for: error)
        }
    }

    /// 存草稿。同样发完催一次同步，草稿箱里才会立刻出现。
    func saveDraft(labels: LabelStore, mail store: MailStore) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let raw = MimeBuilder.build(mail)
            try await GmailAPI(account: mail.fromEmail).createDraft(raw: raw, threadID: mail.threadID)
            didSend = true
            await MailRefresh.account(mail.fromEmail, labels: labels, mail: store, colors: false)
        } catch {
            errorText = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
