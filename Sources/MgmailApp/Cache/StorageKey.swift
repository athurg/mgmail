import Foundation

/// 账号在磁盘上叫什么名字（缓存目录、令牌文件都用它）。
///
/// 邮箱地址不能直接当文件名，而「非字母数字一律换下划线」这种做法会撞车：
/// `a.b@x.com` 和 `a_b@x.com` 会落到同一个路径上，两个账号共用一份缓存、
/// 甚至互相覆盖 refresh token。所以在可读的那一段后面缀一段地址的稳定摘要，
/// 眼睛还认得出是谁，机器也不会认错人。
enum StorageKey {
    /// 账号目录/文件名，形如 `a_b_x_com-3f2a91c4d5e60718`。
    static func account(_ email: String) -> String {
        legacyAccount(email) + "-" + StableHash.suffix(email)
    }

    /// 旧格式（只做替换、不带摘要）。只有一次性迁移还需要它。
    static func legacyAccount(_ email: String) -> String {
        sanitize(email)
    }

    /// 把任意字符串转成安全的文件名（保留字母数字，其余换成下划线）。
    ///
    /// 用在 key 那一层是安全的：那儿放的是 Gmail 的邮件/会话 id，本来就只有
    /// 十六进制字符，替换后不会和别的 id 重名。
    static func sanitize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let scalars = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let result = String(scalars)
        return result.isEmpty ? "_" : result
    }
}
