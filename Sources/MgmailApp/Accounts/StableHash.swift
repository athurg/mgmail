import Foundation

/// 跨进程稳定的字符串哈希（FNV-1a 64 位）。
///
/// 存在的理由是 Swift 的 `String.hashValue` **不能**用在这里：标准库给它掺了
/// 每次启动都不同的随机种子，同一个邮箱地址这次算出 90、下次算出 147。
/// 凡是「由内容推导、且要在两次启动之间保持一致」的东西——头像配色、
/// 文件名后缀——都得用这个，不能用 `hashValue`。
enum StableHash {
    static func value(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325       // FNV offset basis
        for byte in Data(string.utf8) {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3        // FNV prime
        }
        return hash
    }

    /// 取 `0..<upperBound` 的稳定索引（配色取值用）。
    static func index(_ string: String, upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(value(string) % UInt64(upperBound))
    }

    /// 定长十六进制短摘要，用来给文件名消歧。
    ///
    /// 目录名把非字母数字都换成了下划线，`a.b@x.com` 与 `a_b@x.com` 因此会撞到
    /// 同一个路径上；缀上这一段，两个不同的地址就不会共用一份缓存或令牌。
    static func suffix(_ string: String) -> String {
        String(format: "%016llx", value(string))
    }
}
