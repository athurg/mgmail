import AppKit

/// 把光标送进工具栏里的搜索框（⌘F）。
///
/// 搜索框是 SwiftUI 的 `.searchable` 摆进工具栏的，SwiftUI 这边直到 macOS 15
/// 才有聚焦它的 API（`searchFocused`），而本项目跑在 macOS 14 上。好在那个搜索框
/// 落到 AppKit 里就是一个标准的 `NSSearchToolbarItem`，找出来让它自己开始搜索即可。
///
/// 找不到就什么也不做：⌘F 不灵总好过崩一下。
enum SearchFieldFocus {
    static func begin() {
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        guard let item = window?.toolbar?.items
            .compactMap({ $0 as? NSSearchToolbarItem }).first else { return }
        item.beginSearchInteraction()
    }
}
