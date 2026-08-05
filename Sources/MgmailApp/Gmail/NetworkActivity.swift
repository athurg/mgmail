import SwiftUI

/// 按账号统计「正在飞的请求」，供侧栏显示忙碌指示。
///
/// 所有 Gmail 请求都经过 `GmailAPI.sendRaw`，在那里进出计数即可覆盖全部：
/// 列表加载、增量同步、打标签、下载附件、补标签颜色……不用各处埋点。
@MainActor
final class NetworkActivity: ObservableObject {
    static let shared = NetworkActivity()

    /// 当前有请求在飞的账号。
    @Published private(set) var busyAccounts: Set<String> = []

    private var counts: [String: Int] = [:]

    private init() {}

    func begin(_ account: String) {
        counts[account, default: 0] += 1
        publish()
    }

    func end(_ account: String) {
        guard let current = counts[account] else { return }
        if current <= 1 { counts[account] = nil } else { counts[account] = current - 1 }
        publish()
    }

    /// 只在「忙/不忙」真的翻转时才发布。
    /// 请求进出很频繁，每次都赋值会让订阅它的侧栏跟着反复重算。
    private func publish() {
        let fresh = Set(counts.keys)
        if fresh != busyAccounts { busyAccounts = fresh }
    }
}
