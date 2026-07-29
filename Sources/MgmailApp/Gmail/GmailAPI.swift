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

    // MARK: - 会话列表

    func listThreads(labelId: String?, query: String?, pageToken: String?,
                     maxResults: Int = 40, includeSpamTrash: Bool = false) async throws -> ThreadListResponse {
        var items: [URLQueryItem] = [.init(name: "maxResults", value: String(maxResults))]
        if let labelId { items.append(.init(name: "labelIds", value: labelId)) }
        if let query, !query.isEmpty { items.append(.init(name: "q", value: query)) }
        if let pageToken { items.append(.init(name: "pageToken", value: pageToken)) }
        // 按 SPAM/TRASH 过滤、或想包含它们时必须显式开启，否则 Gmail 返回空
        if includeSpamTrash { items.append(.init(name: "includeSpamTrash", value: "true")) }
        let data = try await send(path: "/threads", query: items)
        return try decode(ThreadListResponse.self, data)
    }

    /// 获取会话；format = "full" | "metadata" | "minimal"。
    func getThread(id: String, format: String = "full", metadataHeaders: [String] = []) async throws -> GmailThread {
        var items: [URLQueryItem] = [.init(name: "format", value: format)]
        for h in metadataHeaders { items.append(.init(name: "metadataHeaders", value: h)) }
        let data = try await send(path: "/threads/\(id)", query: items)
        return try decode(GmailThread.self, data)
    }

    func getMessage(id: String, format: String = "full") async throws -> GmailMessage {
        let data = try await send(path: "/messages/\(id)", query: [.init(name: "format", value: format)])
        return try decode(GmailMessage.self, data)
    }

    // MARK: - 修改标签 / 状态

    /// 把会话移入废纸篓（Gmail 的“删除”语义；30 天后自动清除，可从废纸篓恢复）。
    func trashThread(id: String) async throws {
        _ = try await send(path: "/threads/\(id)/trash", method: "POST")
    }

    /// 从废纸篓恢复会话。
    func untrashThread(id: String) async throws {
        _ = try await send(path: "/threads/\(id)/untrash", method: "POST")
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
        try await sendInternal(path: path, method: method, query: query, body: body, allowRetry: true)
    }

    private func sendInternal(path: String, method: String, query: [URLQueryItem], body: Data?, allowRetry: Bool) async throws -> Data {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query }
        var request = URLRequest(url: comps.url!)
        request.httpMethod = method

        let token = try await AuthManager.shared.validAccessToken(for: account, forceRefresh: !allowRetry)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GmailError.http(-1, "无响应")
        }
        if http.statusCode == 401 && allowRetry {
            // access token 可能过期，强制刷新后重试一次
            return try await sendInternal(path: path, method: method, query: query, body: body, allowRetry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GmailError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        if data.isEmpty, let empty = EmptyDecodable() as? T { return empty }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw GmailError.decoding("\(error)")
        }
    }
}

/// 用于 DELETE 等空响应。
private struct EmptyDecodable: Decodable {}
