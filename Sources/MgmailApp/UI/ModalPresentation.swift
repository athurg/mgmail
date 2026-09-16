import AppKit

/// 弹窗（NSAlert、存储 / 打开面板）统一的出场方式：挂在当前窗口上当 sheet。
///
/// 不用 `runModal()` 独立弹：独立弹的那种落在带菜单栏的那块屏幕上（有时还没排上屏），
/// 主窗口在另一台显示器上时用户根本看不见它——点了按钮像是没反应，或者整个应用变灰、
/// 点哪儿都不动；它也不进调度中心，翻遍所有窗口都找不着。sheet 贴在窗口上，窗口在哪
/// 它就在哪。一个窗口都没开的时候（关掉最后一个窗口进程不退出）才退回独立弹窗，这时
/// 把应用拉到前台、弹窗放到鼠标所在的那块屏幕上，至少能被看见。
@MainActor
enum ModalHost {
    /// 弹窗该挂到哪扇窗上：先拿正在用的那扇，其次任何一扇开着的普通窗口。
    static var window: NSWindow? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.windows
        return candidates.lazy.compactMap { $0 }
            .first { $0.isVisible && $0.canBecomeMain && $0.attachedSheet == nil }
    }

    /// 没窗口可挂时独立弹窗的落点：拉到前台，放到鼠标所在的屏幕正中并强制排上屏。
    static func placeStandalone(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            var frame = window.frame
            frame.origin = CGPoint(x: screen.frame.midX - frame.width / 2, y: screen.frame.midY - frame.height / 2)
            window.setFrame(frame, display: false)
        }
        // 应用不在前台时 runModal 不一定把面板排上屏，先强行排上去
        window.orderFrontRegardless()
    }
}

extension NSAlert {
    /// 弹出并等用户点按钮。见 `ModalHost`。
    @discardableResult
    func present() async -> NSApplication.ModalResponse {
        if let host = ModalHost.window {
            host.makeKeyAndOrderFront(nil)
            return await withCheckedContinuation { continuation in
                beginSheetModal(for: host) { continuation.resume(returning: $0) }
            }
        }
        layout()
        ModalHost.placeStandalone(window)
        return runModal()
    }
}

extension NSSavePanel {
    /// 弹出并等用户选好位置或取消。`NSOpenPanel` 继承自它，一并覆盖。见 `ModalHost`。
    func present() async -> NSApplication.ModalResponse {
        if let host = ModalHost.window {
            host.makeKeyAndOrderFront(nil)
            return await withCheckedContinuation { continuation in
                beginSheetModal(for: host) { continuation.resume(returning: $0) }
            }
        }
        ModalHost.placeStandalone(self)
        return runModal()
    }
}
