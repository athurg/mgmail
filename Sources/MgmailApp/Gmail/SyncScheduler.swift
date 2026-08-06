import AppKit
import SwiftUI

/// 后台同步节奏：只有定时器和睡眠唤醒会自动触发，其余都得由用户明确要求。
///
/// 增量同步一次就是一个 `history.list` 请求，没变化时响应只有几百字节，
/// 因此可以按分钟级轮询而不用担心配额；真正贵的全量拉取只在首次加载、
/// 切换邮箱、或位点过期时才发生。
///
/// 刻意不监听 `didBecomeActive`：切回窗口不是「要求刷新」，
/// 频繁切前后台会让请求量脱离用户预期。要立刻同步就点刷新按钮。
///
/// 调度器的持有者是 `MgmailApp` 而不是某个视图——macOS 上关掉最后一个窗口
/// 进程仍在，定时器要是跟着视图一起没了，新邮件通知也就跟着没了。
@MainActor
final class SyncScheduler: ObservableObject {
    /// 上一次同步完成的时间（供界面显示）。
    @Published private(set) var lastSyncedAt: Date?
    /// 是否正在同步（工具栏据此显示转圈）。
    @Published private(set) var isSyncing = false

    private var timer: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// 同步逻辑由外部注入：调度器只管什么时候跑，不管跑什么。
    private var perform: (@MainActor (String) async -> Void)?
    /// 要同步哪些账号，每次触发时现取（账号增删后自动跟上）。
    private var accounts: (@MainActor () -> [String])?

    /// 轮询间隔。
    static let interval: Duration = .seconds(60)

    func start(accounts: @escaping @MainActor () -> [String],
               perform: @escaping @MainActor (String) async -> Void) {
        self.accounts = accounts
        self.perform = perform
        startTimer()
        observeWake()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
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

    /// 合盖一夜再打开，用户期待看到的是新邮件，而不是「再等最多 60 秒」。
    ///
    /// 定时器在睡眠期间是否照常计时并不确定（取决于时钟与 dispatch 的实现），
    /// 所以不去猜——醒来就明确补一次，并把定时器的相位重置到此刻。
    private func observeWake() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.startTimer()
                await self.syncNow()
            }
        }
    }

    /// 立即同步一次。只有定时器和睡眠唤醒会调它——手动刷新走的是侧栏账号行上的按钮，
    /// 那条路直接调 `MailRefresh`，不经过调度器，因此不会被这里的互斥挡住。
    func syncNow() async {
        guard !isSyncing else { return }
        let accounts = self.accounts?() ?? []
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
