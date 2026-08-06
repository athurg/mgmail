import SwiftUI

@main
struct MgmailApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var labelStore = LabelStore()
    /// 全应用唯一的邮件数据源（按账户组织，各邮箱视图都是它的过滤结果）。
    @StateObject private var mailStore = MailStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(labelStore)
                .environmentObject(mailStore)
                .frame(minWidth: 900, minHeight: 560)
                // 提前把 WebKit 渲染进程拉起来，第一封邮件的正文不用等它冷启动
                .task { MessageBodyLayout.warmUp() }
        }
        .windowStyle(.titleBar)
        .commands {
            SidebarCommands()
            NewMailCommand(appState: appState)
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

/// 三栏根视图（仿 Apple Mail）。阶段 1 先搭空壳，后续阶段填充真实内容。
struct RootView: View {
    @EnvironmentObject private var appState: AppState

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
    }
}
