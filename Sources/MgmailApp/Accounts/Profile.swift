import SwiftUI

/// 账号分组（仿 Mimestream 的 Profile）。把若干账号归到一个组，顶部标签切换后只看该组账号的邮件。
///
/// 采用**互斥分组**：一个账号最多属于一个 Profile（成员归属由 `AppState` 维护保证互斥）。
/// 内置的「全部」聚合视图不是 Profile，而是 `currentProfileID == nil` 的特殊态，恒定显示所有账号。
struct Profile: Identifiable, Hashable, Codable {
    let id: String
    var name: String
    /// 颜色在 `Profile.palette` 中的索引（存索引而非 Color，便于 Codable）。
    var colorIndex: Int
    /// 组内账号 email，有序。
    var memberEmails: [String]

    init(id: String = UUID().uuidString, name: String, colorIndex: Int, memberEmails: [String] = []) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.memberEmails = memberEmails
    }

    /// 预设色板（用于标签圆点/描边）。
    static let palette: [Color] = [
        Color(red: 0.22, green: 0.54, blue: 0.87),   // 蓝
        Color(red: 0.11, green: 0.62, blue: 0.46),   // 绿
        Color(red: 0.85, green: 0.35, blue: 0.19),   // 橙红
        Color(red: 0.55, green: 0.36, blue: 0.86),   // 紫
        Color(red: 0.83, green: 0.33, blue: 0.49),   // 粉
        Color(red: 0.73, green: 0.47, blue: 0.09),   // 琥珀
        Color(red: 0.36, green: 0.36, blue: 0.40),   // 灰
    ]

    /// 该 Profile 的代表色。
    var color: Color { Profile.palette[((colorIndex % Profile.palette.count) + Profile.palette.count) % Profile.palette.count] }

    /// 标签上显示的首字。
    var initial: String { String(name.first ?? "?") }
}
