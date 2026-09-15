import SwiftUI

/// 主窗口的三栏布局：侧栏 / 邮件列表 / 正文，自己排、自己拖。
///
/// 不用 `NavigationSplitView`：它在栏与栏之间画一条分栏线、拖动时又会露出窗口的白底，
/// 两样都去不掉，和「三块玻璃浮在一张桌布上」的样子（参考 Telegram）不搭。
/// 这里是一个 HStack，栏宽记在 UserDefaults 里，栏间那 20pt 的桌布空隙就是拖动手柄。
struct ThreePaneLayout<Sidebar: View, List: View, Detail: View>: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("layout.sidebarWidth") private var sidebarWidth: Double = 240
    @AppStorage("layout.listWidth") private var listWidth: Double = 340

    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var list: List
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            if !appState.sidebarHidden {
                sidebar
                    .frame(width: sidebarWidth)
                PaneDivider(width: $sidebarWidth, range: 200...320)
            }
            list
                .frame(width: listWidth)
            PaneDivider(width: $listWidth, range: 280...520)
            detail
                .frame(maxWidth: .infinity)
        }
        .animation(.easeInOut(duration: 0.2), value: appState.sidebarHidden)
    }
}

/// 两栏之间的拖动手柄：本身不占宽度，只在栏间空隙上盖一条看不见的可拖区，
/// 鼠标移上去变左右箭头，拖动改左边那一栏的宽度。
private struct PaneDivider: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    /// 拖动开始时的宽度；nil 表示没在拖。
    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: 0)
            .overlay {
                Color.clear
                    .frame(width: 12)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        hovering = inside
                        // 拖着的时候光标由拖动自己管，别在这儿一进一出地换
                        guard startWidth == nil else { return }
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if startWidth == nil { startWidth = width }
                                width = min(max((startWidth ?? width) + value.translation.width,
                                                range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in
                                startWidth = nil
                                // 拖完鼠标可能已经不在手柄上了，光标得跟着复位
                                if !hovering { NSCursor.pop() }
                            }
                    )
            }
    }
}

/// 「显示 → 显示/隐藏边栏」（⌃⌘S）。系统的 `SidebarCommands` 只认 NavigationSplitView，
/// 三栏改成自己排之后，边栏开合也得自己接。
struct ToggleSidebarCommand: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(appState.sidebarHidden ? "显示边栏" : "隐藏边栏") {
                appState.sidebarHidden.toggle()
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
        }
    }
}
