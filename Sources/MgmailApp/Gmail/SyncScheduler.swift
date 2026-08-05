import SwiftUI
import AppKit

/// 后台同步节奏：定时 + 回到 app 时各跑一次增量同步。
///
/// 增量同步一次就是一个 `history.list` 请求，没变化时响应只有几百字节，
/// 因此可以按分钟级轮询而不用担心配额；真正贵的全量拉取只在首次加载、
/// 切换邮箱、或位点过期时才发生。
@MainActor
final class SyncScheduler: ObservableObject {
    /// 上一次同步完成的时间（供界面显示）。
    @Published private(set) var lastSyncedAt: Date?
    /// 是否正在同步（工具栏据此显示转圈）。
    @Published private(set) var isSyncing = false

    private var timer: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
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
        observeActivation()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
        }
        activationObserver = nil
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

    /// 回到 app 时立刻同步一次：离开期间攒下的变化不必等下一个周期。
    private func observeActivation() {
        guard activationObserver == nil else { return }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.syncNow() }
            }
        }
    }

    /// 立即同步一次（定时、窗口激活、手动刷新都走这里）。
    func syncNow() async {
        guard !isSyncing, let accounts = accounts?(), !accounts.isEmpty else { return }
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
