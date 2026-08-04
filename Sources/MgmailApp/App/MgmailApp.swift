import SwiftUI

@main
struct MgmailApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var labelStore = LabelStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(labelStore)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.titleBar)
        .commands {
            SidebarCommands()
            CommandMenu("账号") {
                SettingsLink {
                    Text("账号与分组…")
                }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                Button(appState.isSigningIn ? "重新开始添加账号…" : "添加账号…") { appState.addAccount() }
                    .disabled(!appState.hasOAuthConfig)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
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
