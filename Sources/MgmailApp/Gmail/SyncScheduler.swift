import SwiftUI

/// 后台同步节奏：只有定时器会自动触发，其余都得由用户明确要求。
///
/// 增量同步一次就是一个 `history.list` 请求，没变化时响应只有几百字节，
/// 因此可以按分钟级轮询而不用担心配额；真正贵的全量拉取只在首次加载、
/// 切换邮箱、或位点过期时才发生。
///
/// 刻意不监听 `didBecomeActive`：切回窗口不是「要求刷新」，
/// 频繁切前后台会让请求量脱离用户预期。要立刻同步就点刷新按钮。
@MainActor
final class SyncScheduler: ObservableObject {
    /// 上一次同步完成的时间（供界面显示）。
    @Published private(set) var lastSyncedAt: Date?
    /// 是否正在同步（工具栏据此显示转圈）。
    @Published private(set) var isSyncing = false

    private var timer: Task<Void, Never>?
    /// 同步逻辑由外部注入：调度器只管什么时候跑，不管跑什么。
    private var perform: (@MainActor (String) async -> Void)?
    /// 要同步哪些账号，每次触发时现取（分组切换后账号会变）。
    private var accounts: (@MainActor () -> [String])?

    /// 轮询间隔。
    static let interval: Duration = .seconds(60)

    func start(accounts: @escaping @MainActor () -> [String],
               perform: @escaping @MainActor (String) async -> Void) {
        self.accounts = accounts
        self.perform = perform
        startTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval)
                if Task.isCancelled { return }
                await self?.syncNow()
            }
        }
    }

    /// 立即同步一次（定时、工具栏刷新、侧栏账号刷新都走这里）。
    ///
    /// `only` 非空时只同步该账号（侧栏是按账号刷新的）。即便它不在当前列表里也照样跑：
    /// 同步会推进该账号的 history 位点，下次它出现在列表里时就不用从头补。
    func syncNow(only: String? = nil) async {
        guard !isSyncing else { return }
        let accounts = only.map { [$0] } ?? (self.accounts?() ?? [])
        guard !accounts.isEmpty else { return }
        isSyncing = true
        defer {
            isSyncing = false
            lastSyncedAt = Date()
        }
        for account in accounts {
            await perform?(account)
        }
    }
}
