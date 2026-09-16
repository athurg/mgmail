import AppKit
import SwiftUI

/// 检查更新的状态机：问 GitHub 有没有新版、下载、装上、重启。
///
/// 触发有三处：定时同步每一轮顺带问一次（按小时节流）、菜单里的「检查更新…」、
/// 设置页里的按钮。后两处是用户明确要的，不节流，结果也直接告诉他；
/// 定时那一路发现新版才出声，而且同一个版本一次启动里只问一遍，
/// 「跳过此版本」则记到磁盘上、下次启动也不再提。
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        /// 下载中，进度 0…1。
        case downloading(UpdateManifest, Double)
        /// 已下载解包，等用户点重启。
        case ready(UpdateManifest, URL)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheckedAt: Date?

    /// 调试用：环境变量 `MGMAIL_UPDATE_MANIFEST_URL` 指到本地起的 HTTP 服务上，
    /// 不用真发一个 Release 也能把下载、校验、替换、重启整条路走一遍。
    static let manifestOverride: URL? = ProcessInfo.processInfo
        .environment["MGMAIL_UPDATE_MANIFEST_URL"].flatMap(URL.init(string:))
    /// 这个进程能不能更新自己：`swift run` 直接跑的裸可执行文件没有 bundle，无从替换；
    /// 开发包（`Mgmail Dev.app`）有 bundle 但换成正式包就不是它自己了，同样不参与——
    /// 除非带着上面那个调试变量启动，那是明确要在开发包上把整条链路走一遍。
    static let isAvailable = AppVersion.current != nil
        && (AppFlavor.current.canSelfUpdate || manifestOverride != nil)
    /// 定时那一路两次检查之间至少隔多久。
    static let minInterval: TimeInterval = 60 * 60

    /// 这次启动里已经弹过窗的构建号（用户点了「稍后」），不再烦他。
    private var promptedBuild: Int?
    /// 打开设置窗口的办法。SwiftUI 的 `openSettings` 只在视图环境里拿得到，由 `RootView` 注入。
    var openSettings: (@MainActor () -> Void)?
    /// 同一时间只跑一个检查/下载。
    private var busy = false
    /// 有弹窗正等用户答复。
    private var prompting = false

    private init() {
        UpdateInstaller.cleanStaging()
    }

    // MARK: - 偏好

    var channel: UpdateChannel {
        UpdateChannel(rawValue: UserDefaults.standard.string(forKey: SettingsKey.updateChannel) ?? "") ?? .stable
    }

    var autoCheck: Bool {
        UserDefaults.standard.object(forKey: SettingsKey.updateAutoCheck) as? Bool ?? true
    }

    private var skippedBuild: Int {
        get { UserDefaults.standard.integer(forKey: SettingsKey.updateSkippedBuild) }
        set { UserDefaults.standard.set(newValue, forKey: SettingsKey.updateSkippedBuild) }
    }

    // MARK: - 检查

    /// 定时同步每一轮都会来问，这里决定要不要真的去查。
    func checkIfDue() async {
        guard Self.isAvailable, autoCheck else { return }
        if let last = lastCheckedAt, Date().timeIntervalSince(last) < Self.minInterval { return }
        // 正在下载或已经下好等重启：别把状态冲掉
        switch phase {
        case .downloading, .ready: return
        default: break
        }
        await check()
        guard case .available(let manifest) = phase else { return }
        guard manifest.build != skippedBuild, manifest.build != promptedBuild else { return }
        promptedBuild = manifest.build
        // 定时发现的：用户多半在别的应用里，Dock 图标跳一下提醒有话要说，不抢焦点
        NSApp.requestUserAttention(.informationalRequest)
        // 不在这里等他答复：这一路是同步每一轮末尾顺带调的，等下去下一轮同步也跟着停
        Task { await offerInstall(manifest) }
    }

    /// 菜单里的「检查更新…」：查完直接告诉用户结果。
    func checkFromMenu() {
        // 上一个弹窗还挂在窗口上，再点一次菜单只会叠出第二个
        guard !prompting else { return }
        Task {
            if case .ready(let manifest, _) = phase {
                await offerRelaunch(manifest)
                return
            }
            await check()
            switch phase {
            case .available(let manifest):
                await offerInstall(manifest)
            case .upToDate:
                let alert = NSAlert()
                alert.messageText = "已是最新版本"
                alert.informativeText = "当前 \(AppVersion.current?.fullText ?? "")，\(channel.title)渠道没有更新的版本。"
                alert.addButton(withTitle: "好")
                await present(alert)
            case .failed(let text):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "检查更新失败"
                alert.informativeText = text
                alert.addButton(withTitle: "好")
                await present(alert)
            default:
                break
            }
        }
    }

    /// 去 GitHub 拿 manifest，和自己比一比。
    func check() async {
        guard let current = AppVersion.current, !busy else { return }
        busy = true
        defer { busy = false }
        phase = .checking
        let url = Self.manifestOverride ?? channel.manifestURL
        let token = ActivityLog.shared.begin(.init(kind: .other, title: "检查更新（\(channel.title)）"),
                                             account: nil, method: "GET", url: url)
        do {
            var request = URLRequest(url: url)
            // GitHub 的跳转目标带签名参数，缓存住就一直是旧的那份
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            guard let http, (200..<300).contains(http.statusCode) else {
                throw UpdateError.badResponse(http?.statusCode)
            }
            let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
            ActivityLog.shared.finish(token, statusCode: http.statusCode, bytes: data.count)
            lastCheckedAt = Date()
            phase = manifest.appVersion > current ? .available(manifest) : .upToDate
        } catch {
            let text = ActivityLog.message(for: error)
            ActivityLog.shared.finish(token, statusCode: nil, error: text)
            lastCheckedAt = Date()
            phase = .failed(text)
        }
    }

    // MARK: - 下载与安装

    /// 下载并解包。完成后停在 `.ready`，什么时候重启由用户定。
    func download() async {
        let manifest: UpdateManifest
        switch phase {
        case .available(let m): manifest = m
        default: return
        }
        guard !busy, let url = URL(string: manifest.url) else { return }
        busy = true
        defer { busy = false }
        phase = .downloading(manifest, 0)
        let token = ActivityLog.shared.begin(.init(kind: .other, title: "下载更新 \(manifest.version)"),
                                             account: nil, method: "GET", url: url)
        do {
            let staged = try await UpdateInstaller.download(manifest, from: url) { fraction in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.phase else { return }
                    self.phase = .downloading(manifest, fraction)
                }
            }
            ActivityLog.shared.finish(token, statusCode: 200, bytes: manifest.size)
            phase = .ready(manifest, staged)
        } catch {
            let text = ActivityLog.message(for: error)
            ActivityLog.shared.finish(token, statusCode: nil, error: text)
            phase = .failed(text)
        }
    }

    /// 换掉自己并重启。失败了停在 `.failed`，旧版本原地不动。
    func installAndRelaunch() {
        guard case .ready(_, let staged) = phase else { return }
        let current = Bundle.main.bundleURL
        do {
            try UpdateInstaller.install(staged: staged, replacing: current)
        } catch {
            phase = .failed(ActivityLog.message(for: error))
            return
        }
        UpdateInstaller.relaunch(current)
    }

    /// 「跳过此版本」：这个构建号以后定时检查不再提，手动检查照样能看到。
    func skip() {
        guard case .available(let manifest) = phase else { return }
        skippedBuild = manifest.build
        phase = .upToDate
    }

    /// 从 `.failed` 回到可以再试的状态。
    func reset() {
        phase = .idle
    }

    // MARK: - 弹窗

    /// 发现新版：问装不装。装的话把设置窗口开到「更新」页让人看得见进度，下完再问一次要不要重启。
    private func offerInstall(_ manifest: UpdateManifest) async {
        let alert = NSAlert()
        alert.messageText = "\(AppFlavor.current.displayName) 有新版本：\(manifest.appVersion.fullText)"
        var lines = ["当前版本 \(AppVersion.current?.fullText ?? "")。"]
        if let notes = manifest.notes, !notes.isEmpty {
            lines.append("")
            lines.append(String(notes.prefix(600)))
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "稍后")
        alert.addButton(withTitle: "跳过此版本")
        switch await present(alert) {
        case .alertFirstButtonReturn:
            showUpdatesPane()
            await download()
            if case .ready = phase { await offerRelaunch(manifest) }
        case .alertThirdButtonReturn:
            skip()
        default:
            break
        }
    }

    /// 下好了：问现在重启还是等会儿。等会儿的话设置页里还有按钮。
    private func offerRelaunch(_ manifest: UpdateManifest) async {
        let alert = NSAlert()
        alert.messageText = "\(manifest.appVersion.description) 已下载好"
        alert.informativeText = "重新启动 Mgmail 即完成安装。开着的撰写窗口会关掉，先把没写完的存成草稿。"
        alert.addButton(withTitle: "重新启动")
        alert.addButton(withTitle: "稍后")
        if await present(alert) == .alertFirstButtonReturn {
            installAndRelaunch()
        }
    }

    /// 弹出 `alert` 并等用户点按钮。挂在当前窗口上当 sheet，出场规则见 `ModalHost`。
    @discardableResult
    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        prompting = true
        defer { prompting = false }
        return await alert.present()
    }

    /// 把设置窗口开到「更新」页，下载进度在那里看。
    private func showUpdatesPane() {
        UserDefaults.standard.set(SettingsTab.updates.rawValue, forKey: SettingsKey.settingsTab)
        openSettings?()
    }
}
