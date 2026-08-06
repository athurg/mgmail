import Foundation

/// 界面上所有的日期文案。
///
/// 存在的理由是 `DateFormatter` 的初始化很贵，而这些文案出现在最热的路径上——
/// 列表每一行一个、会话里每张卡片一个，随便滚一下就是成百上千次。
/// 现建现用的话，光是造格式化器就够拖慢滚动了，所以在这里各造一个长期留着。
///
/// 整个类型限定在主线程：`DateFormatter` 不是线程安全的，而这些文案本来
/// 也只在画界面时用得到。
@MainActor
enum DateText {
    /// 列表行：今天只给时刻，今年之内给月日，再早给年月日。
    static func listRow(_ date: Date?) -> String {
        guard let date else { return "" }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return timeFormatter.string(from: date) }
        if calendar.isDate(date, equalTo: Date(), toGranularity: .year) {
            return monthDayFormatter.string(from: date)
        }
        return shortDateFormatter.string(from: date)
    }

    /// 邮件详情的信头：年月日 + 时刻。
    static func messageHeader(_ date: Date?) -> String {
        guard let date else { return "" }
        return fullDateTimeFormatter.string(from: date)
    }

    /// 「已回溯至 …」这类完整日期。
    static func fullDate(_ date: Date) -> String {
        fullDateFormatter.string(from: date)
    }

    /// 侧栏账号下面那行：今年之内给月日，更早只给到月。
    static func backfill(_ date: Date) -> String {
        Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
            ? monthDayFormatter.string(from: date)
            : yearMonthFormatter.string(from: date)
    }

    /// 多选叠加卡片上的短日期。
    static func card(_ date: Date?) -> String {
        guard let date else { return "" }
        return monthDayFormatter.string(from: date)
    }

    // MARK: - 格式化器（各造一个，长期留着）

    private static let timeFormatter = make("HH:mm")
    private static let monthDayFormatter = make("M月d日")
    private static let shortDateFormatter = make("yyyy/M/d")
    private static let fullDateFormatter = make("yyyy年M月d日")
    private static let fullDateTimeFormatter = make("yyyy年M月d日 HH:mm")
    private static let yearMonthFormatter = make("yyyy年M月")

    private static func make(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        return f
    }
}
