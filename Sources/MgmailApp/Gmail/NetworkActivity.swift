import SwiftUI

/// 按账号统计「正在飞的请求」，供侧栏显示忙碌指示。
///
/// 计数由 `ActivityLog` 在登记活动时顺手驱动，因此覆盖所有联网出口。
/// 之所以和活动日志分成两个对象：日志每来一个请求就变，而侧栏只关心
/// 「这个账号忙不忙」——订阅同一个对象会让整棵侧栏跟着请求节奏重绘。
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
