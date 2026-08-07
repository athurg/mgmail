import AppKit
import UserNotifications

/// 通知的接收端：前台怎么显示，点开之后落到哪。
///
/// 它只负责把「点了哪条通知」记下来并把应用叫到前台，真正的跳转在 `RootView` 里做
/// ——跳转要动 `AppState` 的分组、邮箱、选中项，那是视图层的事，而且主窗口
/// 可能已经关了，得等它重新出现再执行。
@MainActor
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    /// 待处理的跳转。`RootView` 处理完会清空。
    @Published var pending: NotificationRoute?

    private override init() { super.init() }

    /// 挂上通知中心的代理，并注册带快捷操作的通知分类。
    /// 必须在应用启动早期调用，否则冷启动时点通知会丢。
    func install() {
        guard NotificationPermission.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
        NotificationAction.registerCategory()
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// 应用正在前台时也把横幅显示出来，但不响。
    ///
    /// 显示是因为用户可能正看着别的邮箱、别的账号；不响是因为人就在屏幕前，
    /// 再响一声纯属噪音。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let identifier = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            guard let route = NotificationRoute(userInfo: userInfo) else { return }
            // 快捷操作：就地处理掉，不把应用叫到前台——不打断人正是这几个按钮的意义
            if let action = NotificationAction(rawValue: identifier) {
                await NotificationActionHandler.shared.perform(action, route: route)
                return
            }
            guard identifier == UNNotificationDefaultActionIdentifier else { return }
            self.pending = route
            Self.bringToFront()
        }
    }

    // MARK: - 唤回窗口

    /// 把应用叫到前台；主窗口已经关掉时再让它重新开一个。
    ///
    /// 重开走的是「打开自己」——已在运行的应用收到这一下会当成用户点了 Dock 图标，
    /// SwiftUI 的 `WindowGroup` 因此会补出一个窗口。这是从 AppKit 侧唯一能可靠
    /// 触发它的办法：`openWindow` 只在视图里拿得到，而此刻恰恰没有视图。
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        let hasMainWindow = NSApp.windows.contains { $0.canBecomeMain && $0.isVisible }
        guard !hasMainWindow else { return }
        NSWorkspace.shared.open(Bundle.main.bundleURL)
    }
}
