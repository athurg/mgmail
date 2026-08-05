import Foundation

/// 全局请求闸门：限制同时在飞的 Gmail 请求数。
///
/// Gmail 按「每用户每秒 250 quota units」计费，而 `threads.get` 一次就是 10 units。
/// 聚合多账号刷新时很容易瞬间打出上百个请求，撞上 429 之后反而更慢。
/// 这里把并发压在一个可控的数量上，配合退避重试，比放任并发稳得多。
actor RequestGate {
    static let shared = RequestGate(limit: 8)

    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
        running += 1
    }

    func release() {
        running -= 1
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

/// Gmail 的限流退避策略。
enum RetryPolicy {
    /// 最多重试次数（不含首次）。
    static let maxAttempts = 3

    /// 该状态码是否值得退避重试。
    /// 429 是显式限流；403 要看 body——Gmail 把配额超限也放在 403 里，
    /// 但 403 同样用于「无权限」，那种重试没有意义。
    static func shouldRetry(status: Int, body: Data) -> Bool {
        if status == 429 { return true }
        if status == 403, let text = String(data: body, encoding: .utf8) {
            return text.contains("rateLimitExceeded")
                || text.contains("userRateLimitExceeded")
                || text.contains("backendError")
        }
        // 5xx 属于服务端抖动，也值得重试
        return (500...599).contains(status)
    }

    /// 第 n 次重试前等多久：指数退避 + 抖动，避免多个账号同时醒来又一起打过去。
    static func delay(attempt: Int) -> Duration {
        let base = pow(2.0, Double(attempt - 1)) * 0.5     // 0.5s, 1s, 2s
        let jitter = Double.random(in: 0...0.3)
        return .milliseconds(Int((base + jitter) * 1000))
    }
}
