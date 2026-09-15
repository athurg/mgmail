import SwiftUI

/// 一个已登录的 Gmail 账户。阶段 2 起由 OAuth 登录后创建并持久化。
struct Account: Identifiable, Hashable {
    /// 稳定标识，使用账户 email。
    var id: String { email }
    let email: String
    var displayName: String
    /// 用户自定义备注（可空）。
    var note: String = ""
    /// Google 头像 URL（登录时获取，可空）。
    var avatarURL: String?
    /// 用户选的代表色（`#rrggbb`，可空）。多账号混在一个列表里时，每行左侧用它画一道竖条区分来源；
    /// 没选时用 `avatarColor` 从 email 推导的那个色。
    var colorHex: String?

    /// 账号代表色：用户选了就用用户的，没选就由 email 稳定推导。
    ///
    /// 推导用 `StableHash` 而不是 `hashValue`：后者带每次启动都变的随机种子，
    /// 同一个账号会一次一个颜色。
    var avatarColor: Color {
        Color(hexString: colorHex) ?? derivedColor
    }

    /// 没选颜色时的兜底色（由 email 推导）。设置里的「自动」色块也用它预览。
    var derivedColor: Color {
        Color(hue: Double(StableHash.index(email, upperBound: 360)) / 360.0,
              saturation: 0.55, brightness: 0.85)
    }

    /// 设置里可选的代表色。取 macOS 系统色，深浅模式下都看得清，而且和标签色系（Gmail 那套）区分得开。
    static let colorPalette: [String] = [
        "#ff3b30", "#ff9500", "#ffcc00", "#34c759", "#00c7be", "#30b0c7",
        "#007aff", "#5856d6", "#af52de", "#ff2d55", "#a2845e", "#8e8e93",
    ]

    /// 头像里显示的首字母。
    var initial: String {
        String(displayName.first ?? email.first ?? "?").uppercased()
    }
}
