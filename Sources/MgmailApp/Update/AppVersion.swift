import Foundation

/// 一个可比较的版本：`1.9.0` 这样的号，加上构建号。
///
/// 两个号都来自 git（见 `Scripts/app_bundle.sh`）：版本号是最近的 tag，构建号是提交数。
/// 比较时先看版本号，版本号相同再看构建号——main 上每合并一个 PR 构建号就加一，
/// 所以没打 tag 的开发版之间也分得出先后。
struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]
    let build: Int

    init(_ text: String, build: Int) {
        let trimmed = text.hasPrefix("v") ? String(text.dropFirst()) : text
        parts = trimmed.split(separator: ".").map { Int($0) ?? 0 }
        self.build = build
    }

    /// 正在运行的这一份。`swift run` 直接跑的裸可执行文件没有 bundle，也就没有版本，为 nil。
    static let current: AppVersion? = {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        return AppVersion(short, build: build)
    }()

    var description: String { parts.map(String.init).joined(separator: ".") }
    /// 带构建号的写法，如「1.9.0（构建 152）」。
    var fullText: String { "\(description)（构建 \(build)）" }

    /// `1.9` 和 `1.9.0` 算同一个版本，所以不能用合成的 `==`。
    static func == (a: AppVersion, b: AppVersion) -> Bool { compare(a, b) == 0 }
    static func < (a: AppVersion, b: AppVersion) -> Bool { compare(a, b) < 0 }

    private static func compare(_ a: AppVersion, _ b: AppVersion) -> Int {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        if a.build != b.build { return a.build < b.build ? -1 : 1 }
        return 0
    }
}
