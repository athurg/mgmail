import SwiftUI

extension GmailLabel {
    /// 标签背景色（Gmail 的 color.backgroundColor），无则 nil。
    var uiColor: Color? { Color(hexString: color?.backgroundColor) }
    /// 标签文字色。
    var uiTextColor: Color? { Color(hexString: color?.textColor) }

    /// 返回替换了颜色的副本。
    func withColor(_ color: LabelColor) -> GmailLabel {
        GmailLabel(id: id, name: name, type: type,
                   messagesUnread: messagesUnread, messagesTotal: messagesTotal, color: color)
    }
}

extension Color {
    /// 从 "#rrggbb" 十六进制字符串构造颜色；非法返回 nil。
    init?(hexString: String?) {
        guard var hex = hexString else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

/// 每账户的标签缓存，供侧栏与标签编辑器共用。
@MainActor
final class LabelStore: ObservableObject {
    /// 账户 → 标签列表。
    @Published private(set) var labelsByAccount: [String: [GmailLabel]] = [:]

    func labels(for account: String) -> [GmailLabel] {
        labelsByAccount[account] ?? []
    }

    /// 用户自建标签（排除系统标签与类别标签）。
    func userLabels(for account: String) -> [GmailLabel] {
        labels(for: account)
            .filter { !$0.isSystem }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// 正在网络刷新的账户，避免并发重复拉取。
    private var revalidating: Set<String> = []

    /// 加载某账户的标签：先用磁盘缓存 seed，再后台拉最新（SWR）。
    func load(for account: String, force: Bool = false) async {
        // 内存没有则先从磁盘缓存 seed，立即可用
        if labelsByAccount[account] == nil,
           let cached = await MailCache.shared.labels(account: account) {
            labelsByAccount[account] = cached
        }
        // 网络刷新（去重）
        if revalidating.contains(account) && !force { return }
        revalidating.insert(account)
        defer { revalidating.remove(account) }
        do {
            let api = GmailAPI(account: account)
            let fresh = try await api.listLabels()
            // 用已知（缓存）的颜色先补上，避免重复 get
            let knownColors = Dictionary(
                (labelsByAccount[account] ?? []).compactMap { l in l.color.map { (l.id, $0) } },
                uniquingKeysWith: { a, _ in a }
            )
            let merged = fresh.map { label -> GmailLabel in
                guard label.color == nil, let c = knownColors[label.id] else { return label }
                return label.withColor(c)
            }
            labelsByAccount[account] = merged                // 先显示（含已知颜色）
            // labels.list 不含 color，对仍缺色的用户标签逐个 get 补齐
            let enriched = await enrichColors(merged, api: api)
            labelsByAccount[account] = enriched
            await MailCache.shared.saveLabels(enriched, account: account)
        } catch {
            // 刷新失败保留已有（缓存）数据
        }
    }

    /// 对缺少颜色的用户标签补齐 color。
    /// labels.list 不返回颜色，只能逐个 get；用 batch 合成一次往返，
    /// 否则首次加载一个有几十个标签的账号就是几十个请求。
    private func enrichColors(_ labels: [GmailLabel], api: GmailAPI) async -> [GmailLabel] {
        let needIDs = labels.filter { !$0.isSystem && $0.color == nil }.map(\.id)
        guard !needIDs.isEmpty else { return labels }

        let items = needIDs.map { BatchItem(id: $0, path: "/labels/\($0)") }
        guard let responses = try? await api.batchGet(items) else { return labels }

        return labels.map { label in
            guard let result = responses[label.id], result.isSuccess,
                  let fresh = try? JSONDecoder().decode(GmailLabel.self, from: result.body),
                  let color = fresh.color else { return label }
            return label.withColor(color)
        }
    }

    /// 新建标签（可带颜色）后刷新缓存。
    func createLabel(for account: String, name: String, color: LabelColor? = nil) async throws {
        _ = try await GmailAPI(account: account).createLabel(name: name, color: color)
        await load(for: account, force: true)
    }

    /// 更新标签名字与颜色。
    func updateLabel(for account: String, id: String, name: String, color: LabelColor?) async throws {
        try await GmailAPI(account: account).updateLabel(id: id, name: name, color: color)
        await load(for: account, force: true)
    }

    func deleteLabel(for account: String, id: String) async throws {
        try await GmailAPI(account: account).deleteLabel(id: id)
        await load(for: account, force: true)
    }

    /// 由 labelId 找显示名（系统标签给中文名）。
    func displayName(for account: String, labelID: String) -> String {
        if let known = StandardMailbox.all.first(where: { $0.id == labelID }) { return known.name }
        return labels(for: account).first { $0.id == labelID }?.name ?? labelID
    }
}
