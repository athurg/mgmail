import SwiftUI
import AppKit

/// 主窗口（三栏那扇）的场景 id，以及「没有主窗口时再开一扇」。
///
/// 关掉最后一扇主窗口后点 Dock 图标，SwiftUI 本该补开一扇，可这里不会：
/// 「文件 → 新建窗口」被 ⌘N 新邮件替换掉了（见 `NewMailCommand`），SwiftUI 重开窗口
/// 走的正是那个动作，它一没，点 Dock 就只是把应用叫到前台、什么窗口都不出来。
/// 所以重开自己接管：Dock 那一下（`AppDelegate`）和点通知（`NotificationRouter`）
/// 都到这里来，按 id 开主窗口。
enum MainWindow {
    static let id = "main"

    /// 开窗的动作只有 SwiftUI 环境里拿得到，由 `MainWindowCommand` 在菜单栏建起来时交过来。
    /// 它不属于哪一扇窗，主窗口全关了也照样能用。
    @MainActor static var openAction: OpenWindowAction?

    /// 有主窗口就拿到前台，没有就开一扇。
    @MainActor static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: isMain) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }
        openAction?(id: id)
    }

    /// 是不是一扇还开着的主窗口。认的是 SwiftUI 给场景窗口起的 identifier（以场景 id 打头）；
    /// 关掉的窗口已经释放，不在 `NSApp.windows` 里。
    @MainActor private static func isMain(_ window: NSWindow) -> Bool {
        guard window.isVisible || window.isMiniaturized,
              let identifier = window.identifier?.rawValue else { return false }
        return identifier == id || identifier.hasPrefix(id + "-")
    }
}

/// 「窗口 → 主窗口」，顺带把开窗的动作交给 `MainWindow`。
///
/// 菜单项本身也是一条退路：主窗口关掉之后，从这里能把它叫回来。
struct MainWindowCommand: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        let _ = MainWindow.openAction = openWindow
        CommandGroup(before: .windowList) {
            Button("主窗口") { MainWindow.show() }
            Divider()
        }
    }
}
