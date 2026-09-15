import Foundation

/// GitHub Release 上随安装包一起发布的 `manifest.json`（由 `Scripts/package_dist.sh` 生成）。
///
/// 应用不走 GitHub 的 Releases API 而是读这份文件：匿名调用 API 每小时只有 60 次，
/// 而且要从一大坨 JSON 里找 asset；固定路径的 manifest 一个 GET 就够，还顺带把校验和带回来了。
struct UpdateManifest: Codable, Sendable, Equatable {
    let version: String
    let build: Int
    let commit: String
    let channel: String
    let tag: String
    /// 安装包的下载地址。
    let url: String
    let asset: String
    /// 安装包的 SHA-256（十六进制小写）。
    let sha256: String
    let size: Int
    let minSystem: String?
    let builtAt: String?
    /// 更新说明（Markdown，一行一条提交）。
    let notes: String?

    var appVersion: AppVersion { AppVersion(version, build: build) }
    /// 提交号的前 7 位。
    var shortCommit: String { String(commit.prefix(7)) }
}

/// 跟哪条线：只跟 tag，还是 main 上每一次合并。
enum UpdateChannel: String, CaseIterable, Identifiable, Sendable {
    case stable
    case dev

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: return "正式版"
        case .dev: return "开发版"
        }
    }

    var detail: String {
        switch self {
        case .stable: return "只在打了版本号（tag）时更新。"
        case .dev: return "每次有改动合并进 main 就更新，最新但没有经过整轮验证。"
        }
    }

    /// manifest 的固定地址。
    ///
    /// 正式版走 `releases/latest/download/…`——GitHub 把它转到最新的非预发布 Release，
    /// 所以开发版那个预发布不会被当成「最新」。开发版是滚动覆盖的 `main-latest`。
    var manifestURL: URL {
        switch self {
        case .stable: return URL(string: "https://github.com/athurg/mgmail/releases/latest/download/manifest.json")!
        case .dev: return URL(string: "https://github.com/athurg/mgmail/releases/download/main-latest/manifest.json")!
        }
    }
}
