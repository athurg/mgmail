import AppKit
import UserNotifications

/// 通知授权状态，以及「这个进程到底能不能发通知」。
///
/// 后者不是多余的谨慎：`UNUserNotificationCenter.current()` 要求进程是一个注册过的
/// app bundle，直接 `swift run` 出来的裸可执行文件调它会崩。本项目正好支持这种跑法
/// （见 README），所以每一处触碰通知中心的地方都要先过 `isAvailable` 这一关。
@MainActor
final class NotificationPermission: ObservableObject {
    static let shared = NotificationPermission()

    @Published private(set) var status: UNAuthorizationStatus = .notDetermined
    /// 最近一次投递失败（授权被撤销时会在这里出现）。
    @Published private(set) var lastDeliveryError: String?

    /// 这个进程能不能发通知。`swift run` 直接跑时为 false。
    ///
    /// 另外，未签名的 bundle 拿不到稳定的通知身份，所以 `Scripts/build_app.sh`
    /// 找不到签名证书时会明确警告。
    static let isAvailable = Bundle.main.bundleIdentifier != nil

    private init() {}

    /// 首次启动时索要授权；已经决定过的（允许或拒绝）只刷新状态，不再打扰。
    func requestIfNeeded() async {
        guard Self.isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        status = settings.authorizationStatus
        guard settings.authorizationStatus == .notDetermined else { return }
        // badge 一并要上：虽然 Dock 角标不靠它，但请求里带上才不会在
        // 系统设置里显示成「不允许角标」，让用户以为是我们没做
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        status = granted ? .authorized : .denied
    }

    func refresh() async {
        guard Self.isAvailable else { return }
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    func recordDeliveryFailure(_ error: Error) {
        lastDeliveryError = error.localizedDescription
        Task { await refresh() }
    }

    /// 被拒之后只能去系统设置里改，应用自己没法再弹一次授权框。
    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 设置页上的一句话状态。
    var summary: String {
        guard Self.isAvailable else {
            return "当前以未打包的方式运行，系统通知不可用。用 Scripts/build_app.sh 打包后启动即可。"
        }
        switch status {
        case .authorized, .provisional, .ephemeral:
            return "已允许发送通知。"
        case .denied:
            return "系统设置里关闭了 Mgmail 的通知。Dock 角标仍然可用。"
        case .notDetermined:
            return "尚未询问通知权限，收到第一封新邮件时会请求。"
        @unknown default:
            return "通知权限状态未知。"
        }
    }

    var isDenied: Bool { Self.isAvailable && status == .denied }
}
