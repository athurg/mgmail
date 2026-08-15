import SwiftUI
import AppKit

/// 给中栏列表装上「双击某行 → 独立窗口」。
///
/// 走的是 NSTableView 自己的 `doubleAction`，而不是在行上挂 SwiftUI 手势。两条路都试过：
///
/// - `TapGesture(count: 2)`（哪怕 `simultaneousGesture`）会把鼠标事件截在 SwiftUI 这一层，
///   底下的 NSTableView 收不到，**单击就不再选中行了**——等于为了双击把列表点废。
/// - 行背景上挂 `NSClickGestureRecognizer` 也不行：表格的 `mouseDown` 自带事件跟踪循环，
///   第二下被它消费掉，识别器根本凑不满两次。
///
/// 表格原生的 `doubleAction` 则是它自己在数点击次数，单击选中的行为一点不受影响。
///
/// 挂在 List 的背景上，只装一次；行视图上什么都不用加，也就不会牵动 NSTableView 重入
/// （行上加闭包会引发什么，见 `ThreadRowCoordinator` 顶部）。
struct ThreadListDoubleClick: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { InstallerView() }

    /// List 重建时底下的表格可能换了一张，每次布局都补装一次（幂等）。
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? InstallerView)?.install()
    }

    final class InstallerView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 这会儿 List 的表格通常还没搭好，等一拍再找
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        func install() {
            guard let table = enclosingTable(), table.doubleAction != #selector(openInWindow) else { return }
            table.target = self
            table.doubleAction = #selector(openInWindow)
        }

        /// 找中栏这张表：从自己往上走，每层在子树里搜一次。
        ///
        /// 从自己出发而不是从窗口出发很重要——窗口里不止一张表（侧栏也是 List），
        /// 从根上搜会搜到别人家的。
        private func enclosingTable() -> NSTableView? {
            var node: NSView? = self
            while let current = node {
                if let hit = Self.firstTable(in: current) { return hit }
                node = current.superview
            }
            return nil
        }

        private static func firstTable(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            for child in view.subviews {
                if let hit = firstTable(in: child) { return hit }
            }
            return nil
        }

        @objc private func openInWindow(_ sender: Any?) {
            guard let table = sender as? NSTableView ?? enclosingTable() else { return }
            let row = table.clickedRow
            guard row >= 0 else { return } // 点在空白处
            MainActor.assumeIsolated {
                ThreadRowCoordinator.shared.openInWindow(rowAt: row)
            }
        }
    }
}
