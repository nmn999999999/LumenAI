import SwiftUI

@main
struct LumenAIApp: App {
    @StateObject private var modelManager = ModelManager.shared
    @StateObject private var llmService = LLMService()
    @StateObject private var chatStore = ChatStore()
    @StateObject private var agentService = AgentService()
    @StateObject private var theme = ThemeObserver()
    /// 数据安全：切后台/退出时立即落盘（见 body 里的 onChange）
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(modelManager)
                .environmentObject(llmService)
                .environmentObject(chatStore)
                .environmentObject(agentService)
                .environmentObject(theme)
                .tint(theme.current.accentColor)
                .preferredColorScheme(theme.current.preferredColorScheme)
                .task {
                    await autoLoadLastModel()
                    // 滚动更新：启动静默检查 GitHub Release（按设置开关 + 间隔节流）
                    if SettingsStorage.shared.settings.autoCheckUpdate {
                        await UpdateCheckerService.shared.checkIfNeeded()
                    }
                    // 插件：启动静默检查模块更新（1 天节流，服务页显示可更新角标）
                    await PluginManager.shared.checkForUpdatesIfNeeded()
                }
                // 数据安全：切后台/退出时立即落盘对话，防止 500ms 防抖窗口内强杀 App 丢消息
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        chatStore.flushSave()
                    }
                }
        }
    }

    /// ThemeObserver 是 AppStorage 包装,主题变更时通知整个视图树重新 .tint(...)
    final class ThemeObserver: ObservableObject {
        @AppStorage("appTheme") var raw: String = AppTheme.system.rawValue
        var current: AppTheme {
            get { AppTheme(rawValue: raw) ?? .system }
            set { raw = newValue.rawValue; objectWillChange.send() }
        }
    }

    /// 启动时自动加载上一次使用的模型（若仍在本地）。
    /// 注意：不再在「本地没有任何模型」时自动下载默认模型 —— 用户明确不要每次进 App 都触发下载。
    /// 是否下载/加载哪个本地模型完全由用户在「模型」页手动选择。
    private func autoLoadLastModel() async {
        guard case .idle = llmService.state,
              let stored = modelManager.lastUsedModel else { return }
        let url = modelManager.localFileURL(for: stored)
        if FileManager.default.fileExists(atPath: url.path) {
            await llmService.load(url: url, displayName: stored.name)
        }
    }
}
