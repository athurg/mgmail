import Foundation

enum GmailError: LocalizedError {
    case http(Int, String)
    case decoding(String)
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Gmail API 返回 \(code)：\(body)"
        case .decoding(let m): return "解析响应失败：\(m)"
        case .notAuthorized: return "账户未授权，请重新登录。"
        }
    }
}

/// Gmail REST 客户端（针对单个账户）。
/// 自动注入 access token；遇 401 刷新一次后重试。
struct GmailAPI {
    let account: String
    private let base = "https://gmail.googleapis.com/gmail/v1/users/me"

    // MARK: - 标签

    func listLabels() async throws -> [GmailLabel] {
        struct Resp: Decodable { let labels: [GmailLabel]? }
        let data = try await send(path: "/labels")
        return try decode(Resp.self, data).labels ?? []
    }

    /// 获取单个标签的完整信息（含 color，list 接口不返回颜色，需 get）。
    func getLabel(id: String) async throws -> GmailLabel {
        let data = try await send(path: "/labels/\(id)")
        return try decode(GmailLabel.self, data)
    }

    func createLabel(name: String, color: LabelColor? = nil) async throws -> GmailLabel {
        struct Body: Encodable {
            let name: String
            let labelListVisibility = "labelShow"
            let messageListVisibility = "show"
            let color: LabelColor?
        }
        let body = try JSONEncoder().encode(Body(name: name, color: color))
        let data = try await send(path: "/labels", method: "POST", body: body)
        return try decode(GmailLabel.self, data)
    }

    func updateLabel(id: String, name: String, color: LabelColor? = nil) async throws {
        struct Body: Encodable {
            let name: String
            let color: LabelColor?
        }
        let body = try JSONEncoder().encode(Body(name: name, color: color))
        _ = try await send(path: "/labels/\(id)", method: "PATCH", body: body)
    }

    func deleteLabel(id: String) async throws {
        _ = try await send(path: "/labels/\(id)", method: "DELETE")
    }

    // MARK: - 邮件列表

    /// 拉一页邮件 id。
    ///
    /// 只有这一个列表接口，没有对应的 `threads.list`：邮件按账户整批进本地池子后，
    /// 「按会话合并」是在本地对同一份数据分组算出来的，不必再向服务器要一遍。
    func listMessages(labelId: String?, query: String?, pageToken: String?,
                      maxResults: Int = 40, includeSpamTrash: Bool = false) async throws -> MessageListResponse {
        var items: [URLQueryItem] = [.init(name: "maxResults", value: String(maxResults))]
        if let labelId { items.append(.init(name: "labelIds", value: labelId)) }
        if let query, !query.isEmpty { items.append(.init(name: "q", value: query)) }
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        // 按 SPAM/TRASH 过滤、或想包含它们时必须显式开启，否则 Gmail 返回空
        if includeSpamTrash { items.append(.init(name: "includeSpamTrash", value: "true")) }
        let data = try await send(path: "/messages", query: items)
        return try decode(MessageListResponse.self, data)
    }

    /// 获取会话；format = "full" | "metadata" | "minimal"。
    func getThread(id: String, format: String = "full", metadataHeaders: [String] = []) async throws -> GmailThread {
        var items: [URLQueryItem] = [.init(name: "format", value: format)]
        for h in metadataHeaders { items.append(.init(name: "metadataHeaders", value: h)) }
        let data = try await send(path: "/threads/\(id)", query: items)
        return try decode(GmailThread.self, data)
    }

    func getMessage(id: String, format: String = "full", metadataHeaders: [String] = []) async throws -> GmailMessage {
        var items: [URLQueryItem] = [.init(name: "format", value: format)]
        for h in metadataHeaders { items.append(.init(name: "metadataHeaders", value: h)) }
        let data = try await send(path: "/messages/\(id)", query: items)
        return try decode(GmailMessage.self, data)
    }

    // MARK: - 修改标签 / 状态

    /// 把会话移入废纸篓（Gmail 的“删除”语义；30 天后自动清除，可从废纸篓恢复）。
    func trashThread(id: String) async throws {
        _ = try await send(path: "/threads/\(id)/trash", method: "POST")
    }

    /// 把单封邮件移入废纸篓（不按会话显示时用）。
    func trashMessage(id: String) async throws {
        _ = try await send(path: "/messages/\(id)/trash", method: "POST")
    }

    /// 把会话从废纸篓里捞回来。
    ///
    /// 单独一个接口，不能靠 `modify` 去掉 TRASH 标签——Gmail 不接受那样改。
    /// 捞回来之后落在哪由调用方再发一次 `modify` 定（这个应用一律送回收件箱）。
    func untrashThread(id: String) async throws {
        _ = try await send(path: "/threads/\(id)/untrash", method: "POST")
    }

    /// 把单封邮件从废纸篓里捞回来（不按会话显示时用）。
    func untrashMessage(id: String) async throws {
        _ = try await send(path: "/messages/\(id)/untrash", method: "POST")
    }

    func modifyThread(id: String, add: [String] = [], remove: [String] = []) async throws {
        let body = try JSONEncoder().encode(ModifyRequest(
            addLabelIds: add.isEmpty ? nil : add,
            removeLabelIds: remove.isEmpty ? nil : remove
        ))
        _ = try await send(path: "/threads/\(id)/modify", method: "POST", body: body)
    }

    func modifyMessage(id: String, add: [String] = [], remove: [String] = []) async throws {
        let body = try JSONEncoder().encode(ModifyRequest(
            addLabelIds: add.isEmpty ? nil : add,
            removeLabelIds: remove.isEmpty ? nil : remove
        ))
        _ = try await send(path: "/messages/\(id)/modify", method: "POST", body: body)
    }

    // MARK: - 增量同步

    /// 取账号档案，主要是为了拿当前 historyId 作为增量同步的起点。
    func getProfile() async throws -> GmailProfile {
        let data = try await send(path: "/profile")
        return try decode(GmailProfile.self, data)
    }

    /// 拉取自 `startHistoryId` 以来的变化。
    ///
    /// startHistoryId 太旧时 Gmail 返回 404（Gmail 只保留约一周的历史），
    /// 调用方需要据此回退到全量刷新。
    func listHistory(startHistoryId: String, pageToken: String? = nil,
                     maxResults: Int = 500) async throws -> HistoryListResponse {
        var items: [URLQueryItem] = [
            .init(name: "startHistoryId", value: startHistoryId),
            .init(name: "maxResults", value: String(maxResults)),
        ]
        // 只关心这四类；不加的话连 draft 变化都会回来
        for type in ["messageAdded", "messageDeleted", "labelAdded", "labelRemoved"] {
            items.append(.init(name: "historyTypes", value: type))
        }
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        let data = try await send(path: "/history", query: items)
        return try decode(HistoryListResponse.self, data)
    }

    // MARK: - 发信

    /// 发送一封已拼好的 RFC 2822 报文。
    ///
    /// `threadID` 给了这封才会落进原会话（回复时必须带，否则 Gmail 另起一串）。
    /// 走 JSON 简单上传，Gmail 对这条路的报文上限是 5MB——附件大小在
    /// 撰写界面就拦掉了，这里不再判断。
    @discardableResult
    func sendMessage(raw: Data, threadID: String? = nil) async throws -> GmailMessage {
        let body = try JSONEncoder().encode(RawMessageRequest(raw: base64URL(raw), threadId: threadID))
        let data = try await send(path: "/messages/send", method: "POST", body: body)
        return try decode(GmailMessage.self, data)
    }

    /// 存草稿。Gmail 的草稿也是一封完整报文，只是没发出去。
    @discardableResult
    func createDraft(raw: Data, threadID: String? = nil) async throws -> GmailDraft {
        struct Body: Encodable { let message: RawMessageRequest }
        let body = try JSONEncoder().encode(
            Body(message: RawMessageRequest(raw: base64URL(raw), threadId: threadID))
        )
        let data = try await send(path: "/drafts", method: "POST", body: body)
        return try decode(GmailDraft.self, data)
    }

    /// Gmail 的 raw 字段要 base64url（无填充）。
    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 附件

    func getAttachment(messageID: String, attachmentId: String) async throws -> Data {
        struct Resp: Decodable { let data: String? }
        let data = try await send(path: "/messages/\(messageID)/attachments/\(attachmentId)")
        let resp = try decode(Resp.self, data)
        guard let d = resp.data, let bytes = MimeParser.decodeBase64URL(d) else {
            throw GmailError.decoding("附件数据为空")
        }
        return bytes
    }

    // MARK: - 底层请求

    private func send(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query }
        return try await sendRaw(url: comps.url!, method: method, body: body,
                                 contentType: body == nil ? nil : "application/json")
    }

    /// 所有 Gmail 请求的唯一出口：活动记录 → 并发闸门 → token 注入 → 401 刷新重试 → 限流退避重试。
    ///
    /// 活动日志在这里登记，因此每一个 Gmail 请求都会自动出现在活动窗口里，
    /// 新加的接口不用另外埋点。`activity` 只在 URL 看不出内容时才需要给（批量请求）。
    func sendRaw(url: URL, method: String, body: Data?, contentType: String?,
                 activity: ActivityDescriptor? = nil) async throws -> Data {
        let account = self.account
        let logToken = await ActivityLog.shared.begin(
            activity ?? .infer(url: url, method: method),
            account: account, method: method, url: url
        )
        await RequestGate.shared.acquire()
        defer { Task { await RequestGate.shared.release() } }

        var refreshedOnce = false
        var attempt = 0

        do {
            while true {
                var request = URLRequest(url: url)
                request.httpMethod = method
                let token = try await AuthManager.shared.validAccessToken(for: account,
                                                                         forceRefresh: refreshedOnce)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                if let body {
                    request.httpBody = body
                    if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
                }

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw GmailError.http(-1, "无响应")
                }

                if (200..<300).contains(http.statusCode) {
                    await ActivityLog.shared.finish(logToken, statusCode: http.statusCode,
                                                    bytes: data.count)
                    return data
                }

                // access token 过期：强制刷新后重来一次
                if http.statusCode == 401, !refreshedOnce {
                    refreshedOnce = true
                    continue
                }

                // 限流 / 服务端抖动：退避后重试
                if attempt < RetryPolicy.maxAttempts,
                   RetryPolicy.shouldRetry(status: http.statusCode, body: data) {
                    attempt += 1
                    await ActivityLog.shared.retried(logToken)
                    try? await Task.sleep(for: RetryPolicy.delay(attempt: attempt))
                    continue
                }

                throw GmailError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
            }
        } catch {
            var status: Int?
            if case let GmailError.http(code, _) = error { status = code }
            await ActivityLog.shared.finish(logToken, statusCode: status,
                                            error: ActivityLog.message(for: error))
            throw error
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GmailError.decoding("\(error)")
        }
    }
}
