import SwiftUI

@main
struct MgmailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @StateObject private var labelStore = LabelStore()
    /// 全应用唯一的邮件数据源（按账户组织，各邮箱视图都是它的过滤结果）。
    @StateObject private var mailStore = MailStore()
    /// 后台同步的节奏控制。
    ///
    /// 挂在 App 上而不是列表视图上：macOS 关掉最后一个窗口进程并不退出，
    /// 定时器若跟着视图一起没了，新邮件通知也就跟着没了。
    @StateObject private var sync = SyncScheduler()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(labelStore)
                .environmentObject(mailStore)
                .environmentObject(sync)
                .frame(minWidth: 900, minHeight: 560)
                // 提前把 WebKit 渲染进程拉起来，第一封邮件的正文不用等它冷启动
                .task { MessageBodyLayout.warmUp() }
        }
        .windowStyle(.titleBar)
        .commands {
            SidebarCommands()
            NewMailCommand(appState: appState)
            SearchMailCommand(appState: appState)
            // 账号已在「设置」里统一管理，不再单独开菜单。
            // 「活动」窗口由下面的 Window 场景自动出现在「窗口」菜单里（⌘0）。
        }

        // 撰写窗口。每封信一个窗口，所以是 WindowGroup 而不是单例 Window；
        // 窗口值只是个 id，内容在 ComposeStore 里按 id 领。
        WindowGroup(id: ComposeWindow.id, for: UUID.self) { $composeID in
            if let composeID {
                ComposeView(composeID: composeID)
                    .environmentObject(appState)
                    .environmentObject(labelStore)
                    .environmentObject(mailStore)
            }
        }
        .defaultSize(width: 680, height: 520)
        // 不进「窗口 → 新建」菜单：新邮件有自己的 ⌘N，从那儿走才带得上发件人
        .commandsRemoved()

        // 双击列表行弹出的独立邮件窗口。窗口值就是那一行的 key，
        // 同一封邮件再双击时 SwiftUI 认这个值，把开着的那扇拿到前台而不是再开一扇。
        WindowGroup(id: MessageWindow.id, for: SelectedThread.self) { $target in
            if let target {
                MessageWindowView(target: target)
                    .environmentObject(appState)
                    .environmentObject(labelStore)
                    .environmentObject(mailStore)
            }
        }
        // 纯阅读窗口：标题栏和工具栏都不要，整块地方留给正文，只剩三个圆点浮在左上角
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 640)
        // 不进「窗口 → 新建」菜单：这扇窗只能从某一封具体的邮件上开出来
        .commandsRemoved()

        // 网络活动日志（仿 Apple Mail 的「活动」窗口，⌘0）。单例窗口，不跟主窗口走。
        Window("活动", id: ActivityWindow.id) {
            ActivityLogView()
        }
        .defaultSize(width: 860, height: 460)
        .keyboardShortcut("0", modifiers: .command)

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(mailStore)
        }
    }
}

/// 应用级的生命周期钩子。
///
/// 目前只做一件事：尽早挂上通知中心的代理。这必须在应用启动的最初阶段完成——
/// 从通知点进来的冷启动，系统会在启动后立刻把「点了哪条」交给代理，
/// 那时候还没有任何视图，晚一步就丢了。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationRouter.shared.install()
    }
}

/// 「文件 → 新邮件」（⌘N）。
///
/// 发件人取当前侧栏选中的那个账号，没选中就用第一个；一个账号都没有时按钮置灰
/// ——没登录也就无从发信。
struct NewMailCommand: Commands {
    // 菜单栏拿不到 WindowGroup 里注入的环境对象，只能由 App 直接传进来
    @ObservedObject var appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新邮件") {
                guard let account = appState.composeAccount else { return }
                openWindow(id: ComposeWindow.id, value: ComposeStore.shared.newMail(from: account))
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(appState.composeAccount == nil)
        }
    }
}

/// 「编辑 → 搜索邮件」（⌘F）。
///
/// 只把光标送进中栏的搜索框，搜什么、怎么搜都在那边——这里够不着视图的焦点状态，
/// 所以经 `AppState` 转一手（和「删除」「开新窗口」那几个请求一个路数）。
struct SearchMailCommand: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("搜索邮件") { appState.requestSearchFocus() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(appState.selection == nil)
        }
    }
}

/// 三栏根视图（仿 Apple Mail）。阶段 1 先搭空壳，后续阶段填充真实内容。
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var labelStore: LabelStore
    @EnvironmentObject private var mailStore: MailStore
    @EnvironmentObject private var sync: SyncScheduler
    @ObservedObject private var router = NotificationRouter.shared
    /// 行 id 的语义随它变（会话模式下是 threadId，否则是 messageId），跳转要按它来。
    @AppStorage(SettingsKey.conversationView) private var conversationView = false

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                SidebarView()
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            } content: {
                ThreadListView()
                    .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 520)
            } detail: {
                MessageDetailView()
            }
            // 标题挂在分栏视图自己身上：外面套了 VStack 之后，它不再是窗口的根视图
            .navigationTitle("Mgmail")
            // 横贯整个窗口底部的网络活动栏（没有活动时不占位）
            ActivityStatusBar()
        }
        .sheet(isPresented: Binding(
            get: { !appState.hasOAuthConfig },
            set: { _ in }
        )) {
            SetupView()
                .environmentObject(appState)
        }
        .alert("出错了", isPresented: Binding(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .task {
            // 定时同步覆盖**全部**账号（不只当前分组），否则分组外的来信永远发现不了，
            // 也就永远不会通知。代价是它们的池子也得先从磁盘恢复：池子里存着拉取游标，
            // 不恢复就等于游标丢失，定时器会把那个账号当新账号从头全量拉一遍。
            await mailStore.restore(accounts: appState.accounts.map(\.id))
            // 调度器本身活在 App 上，这里只是把「同步什么」告诉它。
            // 视图重建时再调一次是幂等的，旧定时器会被换掉。
            NewMailNotifier.shared.accountName = { [weak appState] email in
                appState?.accounts.first { $0.id == email }?.displayName ?? email
            }
            // 通知里的快捷操作要改本地池子。它可能在主窗口关着的时候触发，
            // 但池子活在 App 上，注入一次就一直有效。
            NotificationActionHandler.shared.store = mailStore
            sync.start(accounts: { appState.accounts.map(\.id) }) { account in
                await MailRefresh.account(account, labels: labelStore, mail: mailStore, colors: false)
            }
            // 没有账号就没有邮件，这时候索要通知权限只是打扰
            if !appState.accounts.isEmpty {
                await NotificationPermission.shared.requestIfNeeded()
            }
        }
        // 点了通知：主窗口可能刚被重新打开，落点在这里执行
        .onChange(of: router.pending, initial: true) { _, route in
            guard let route else { return }
            open(route)
            router.pending = nil
        }
    }

    /// 跳到通知里那封邮件。
    ///
    /// 邮件可能属于当前分组之外的账号——那种情况下先回到「全部」，
    /// 否则跳过去了也看不见，用户只会觉得点了没反应。
    private func open(_ route: NotificationRoute) {
        if !appState.activeAccounts.contains(where: { $0.id == route.account }) {
            appState.setCurrentProfile(nil)
        }
        appState.selection = MailboxSelection(accountID: nil, labelID: "INBOX", labelName: "收件箱")
        guard let messageID = route.messageID, let threadID = route.threadID else { return }
        // 推迟一拍：列表要先按新的 selection 重算，选中项才落得住
        let rowID = conversationView ? threadID : messageID
        Task { @MainActor in
            appState.selectedThreads = [SelectedThread(accountID: route.account, threadID: rowID)]
        }
    }
}
