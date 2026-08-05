import Foundation

/// 批量请求里的一条子请求。
struct BatchItem {
    /// 调用方用来对应结果的标识（会写进 Content-ID）。
    let id: String
    /// 相对 `/gmail/v1/users/me` 的路径，如 `/threads/abc`。
    let path: String
    let query: [URLQueryItem]

    init(id: String, path: String, query: [URLQueryItem] = []) {
        self.id = id
        self.path = path
        self.query = query
    }
}

/// 批量请求里的一条子响应。
struct BatchResult {
    let status: Int
    let body: Data

    var isSuccess: Bool { (200..<300).contains(status) }
}

extension GmailAPI {
    /// Gmail 单批上限 100 条；官方建议不要更大。
    static let batchLimit = 100

    /// 把多个 GET 合并成一次 HTTP 往返。
    ///
    /// 列表加载原本是「1 次 list + N 次 get」，一页 40 封就是 41 个请求，
    /// 聚合多账号时成倍放大，既慢又容易撞配额（threads.get 每次 10 quota units）。
    /// 合并后一页只要 2 个请求。
    ///
    /// 返回值按 `BatchItem.id` 索引；子请求各自成败互不影响，失败的那条也会带着状态码回来。
    func batchGet(_ items: [BatchItem]) async throws -> [String: BatchResult] {
        guard !items.isEmpty else { return [:] }

        var merged: [String: BatchResult] = [:]
        for chunk in items.chunked(into: Self.batchLimit) {
            let part = try await sendBatch(chunk)
            merged.merge(part) { a, _ in a }
        }
        return merged
    }

    private func sendBatch(_ items: [BatchItem]) async throws -> [String: BatchResult] {
        let boundary = "mgmail-batch-\(UUID().uuidString)"
        var body = Data()

        for item in items {
            var comps = URLComponents()
            comps.path = "/gmail/v1/users/me" + item.path
            if !item.query.isEmpty { comps.queryItems = item.query }
            // percentEncodedString 里的 + 等字符已由 URLComponents 处理
            let target = comps.string ?? comps.path

            body.append("--\(boundary)\r\n")
            body.append("Content-Type: application/http\r\n")
            body.append("Content-ID: <\(item.id)>\r\n\r\n")
            body.append("GET \(target)\r\n\r\n")
        }
        body.append("--\(boundary)--\r\n")

        let data = try await sendRaw(
            url: URL(string: "https://gmail.googleapis.com/batch/gmail/v1")!,
            method: "POST",
            body: body,
            contentType: "multipart/mixed; boundary=\(boundary)"
        )
        return Self.parseBatchResponse(data)
    }

    /// 解析 multipart/mixed 响应：按 boundary 切块，每块里再解析内嵌的 HTTP 响应。
    ///
    /// 响应的 Content-ID 形如 `<response-item1>`，对应请求里的 `<item1>`。
    static func parseBatchResponse(_ data: Data) -> [String: BatchResult] {
        guard let text = String(data: data, encoding: .utf8) else { return [:] }
        // 首行就是 boundary（带 -- 前缀）
        guard let firstLine = text.split(separator: "\r\n", maxSplits: 1).first,
              firstLine.hasPrefix("--") else { return [:] }
        let boundary = String(firstLine)

        var results: [String: BatchResult] = [:]
        for rawPart in text.components(separatedBy: boundary) {
            let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty, part != "--" else { continue }

            // part 结构：外层头 \r\n\r\n 内嵌 HTTP 响应（状态行 + 头 \r\n\r\n body）
            let sections = part.components(separatedBy: "\r\n\r\n")
            guard sections.count >= 2 else { continue }

            guard let id = Self.contentID(in: sections[0]) else { continue }
            let statusLine = sections[1].split(separator: "\r\n").first.map(String.init) ?? ""
            let status = Self.statusCode(from: statusLine) ?? 0
            // 第 3 段起是 body（body 自身可能含空行，拼回去）
            let bodyText = sections.count >= 3
                ? sections[2...].joined(separator: "\r\n\r\n")
                : ""
            results[id] = BatchResult(status: status, body: Data(bodyText.utf8))
        }
        return results
    }

    /// 从头部块里取 Content-ID，并去掉 Gmail 加的 `response-` 前缀。
    private static func contentID(in headers: String) -> String? {
        for line in headers.split(separator: "\r\n") {
            let lower = line.lowercased()
            guard lower.hasPrefix("content-id:") else { continue }
            var value = line.dropFirst("content-id:".count).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("<") { value.removeFirst() }
            if value.hasSuffix(">") { value.removeLast() }
            if value.hasPrefix("response-") { value.removeFirst("response-".count) }
            return value
        }
        return nil
    }

    /// "HTTP/1.1 200 OK" → 200
    private static func statusCode(from line: String) -> Int? {
        let parts = line.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

extension Array {
    /// 按固定大小切片。
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, count > size else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
