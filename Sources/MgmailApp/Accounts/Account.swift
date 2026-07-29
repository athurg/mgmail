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

    /// 侧栏头像颜色（由 email 稳定推导）。
    var avatarColor: Color {
        let hue = Double(abs(email.hashValue) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.85)
    }

    /// 头像里显示的首字母。
    var initial: String {
        String(displayName.first ?? email.first ?? "?").uppercased()
    }
}
