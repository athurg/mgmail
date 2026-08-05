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
            // 账号已在「设置」里统一管理，不再单独开菜单。
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .environmentObject(mailStore)
        }
    }
}

/// 三栏根视图（仿 Apple Mail）。阶段 1 先搭空壳，后续阶段填充真实内容。
struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            ThreadListView()
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 520)
        } detail: {
            MessageDetailView()
        }
        .navigationTitle("Mgmail")
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
