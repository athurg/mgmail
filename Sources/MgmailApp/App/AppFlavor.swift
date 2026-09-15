import Foundation

/// 这个进程是哪种包：正式包（分发、CI 出的 `Mgmail.app`）还是开发包（本机 `Scripts/build_app.sh`
/// 出的 `Mgmail Dev.app`）。由打包脚本写进 Info.plist 的 `MgmailFlavor` 决定，见 `Scripts/app_bundle.sh`。
///
/// 两种包名字、bundle id、图标都不同，所以 Dock 里认得出、UserDefaults 天然分开；
/// 这里再把**数据目录**分开——两个进程写同一份同步位点和邮件池，谁也说不清池子里是什么。
/// 首次启动会从正式包克隆一份数据快照（`DevSeed`），不必重新添加账号、重新同步。
///
/// 开发包也不参与自动更新：它替换不成正式包（换上去名字、id 全变了），正式包也替换不了它。
enum AppFlavor: String, Sendable {
    case release
    case dev

    /// 正在运行的这一份。`swift run` 直接跑的裸可执行文件没有 bundle，也按开发包算——
    /// 它从来不是装出来的，没道理去碰正式包的数据。
    static let current: AppFlavor = {
        guard Bundle.main.bundleIdentifier != nil else { return .dev }
        let raw = Bundle.main.infoDictionary?["MgmailFlavor"] as? String ?? ""
        return AppFlavor(rawValue: raw) ?? .release
    }()

    /// 给人看的名字，和 Info.plist 里的 CFBundleName 一致。
    var displayName: String {
        switch self {
        case .release: return "Mgmail"
        case .dev: return "Mgmail Dev"
        }
    }

    /// `~/Library/Application Support/` 下的目录名。
    var supportDirectoryName: String { displayName }

    /// 能不能从 GitHub Release 更新自己。
    var canSelfUpdate: Bool { self == .release }
}
