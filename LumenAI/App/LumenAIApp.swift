import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 只为两件系统级事件存在：**后台下载的回调**与**App 被系统唤起**。
///
/// 为什么必须有它：后台 URLSession 在传输完成时会把 App 拉起来，并调用
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)` ——
/// SwiftUI 的 App 生命周期没有对应的钩子，不接这个回调就等于
/// "下载在后台完成了，但没人知道"。具体后果有两个：
///   1. 系统给的那个 completionHandler 没有被调用 → 系统判定我们没处理完，
///      **之后不再唤起这个 App**（表现：第一次切后台还能下，之后再也收不到完成通知）；
///   2. 不知道该重建哪个会话 → 那些传输的结果永远拿不到。
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 正常启动也要续传：上次退出时正在下的模型不应该被默默放弃。
        ModelManager.shared.resumePendingDownloads()

        // 注册灵动岛授权按钮的处理：App 启动（含被系统在后台拉起）时挂上。
        // 必须在**启动时**注册，而且必须**同步** —— 这里原来写的是
        // `Task { @MainActor in ApprovalBridge.resolver = ... }`，那是异步的：
        // 用户按下灵动岛按钮时系统才把 App 拉起来，如果意图执行得比这个 Task 早，
        // resolver 还是 nil，那次点击就**静默失效**了；而用户切回 App 后弹窗关闭
        // 又会被当成"拒绝"—— 于是"我点了允许，回去看到被拒绝了"。
        // didFinishLaunchingWithOptions 本身就在主线程上，直接同步注册即可。
        ApprovalBridge.resolver = { approve in
            Task { @MainActor in
                AgentApprovalCenter.shared.resolveFromLiveActivity(approve: approve)
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // identifier 必须与我们建会话时用的完全一致，否则说明这是别的会话的事件
        // （或标识符被改过），此时**不要**接管：接错了会把回调安到错误的会话上。
        guard identifier == ModelManager.backgroundSessionID else {
            completionHandler()
            return
        }
        ModelManager.backgroundCompletionHandler = completionHandler
        ModelManager.shared.reattachBackgroundSession()
        // 被系统唤起时进程是全新的，内存里没有任何进行中的下载状态 ——
        // 从落盘的清单恢复，否则传完的文件不知道该存成哪个名字。
        ModelManager.shared.resumePendingDownloads()
    }
}

@main
struct LumenAIApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @StateObject private var modelManager = ModelManager.shared
    @StateObject private var llmService = LLMService()
    @StateObject private var chatStore = ChatStore()
    @StateObject private var agentService = AgentService()
    @StateObject private var theme = ThemeObserver()
    @Environment(\.colorScheme) private var colorScheme
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
                // 通透的前提：玻璃要透得见「下层」。垫一层与页面同源的渐变作为
                // 窗口底色，毛玻璃卡片、列表间隙、推送出来的子页面才显出层次
                // （见 AppBackdrop / AppTheme.pageColors 注释）。
                .background {
                    AppBackdrop(colors: theme.current.pageColors(for: colorScheme))
                        .ignoresSafeArea()
                }
                .task {
                    await autoLoadLastModel()
                    // 滚动更新：启动静默检查 GitHub Release（按设置开关 + 间隔节流）
                    if SettingsStorage.shared.settings.autoCheckUpdate {
                        await UpdateCheckerService.shared.checkIfNeeded()
                    }
                    // 插件：启动静默检查模块更新（1 天节流，服务页显示可更新角标）
                    await PluginManager.shared.checkForUpdatesIfNeeded()

                    // v0.3.74：两个本地 TTS 引擎（CosyVoice / Kokoro）**不再启动预热**，
                    // 改为手动加载 —— 启动期是主线程布局的高峰，预热的 tokenizer/着色器
                    // 编译会跟首帧抢 CPU（0.3.73 的卡顿报告正是这条路径）。
                    // 按需加载的入口本来就有：设置页「测试本地语音 / 试听」按钮、
                    // 聊天里点「朗读」时 TTSService 会自己加载引擎（带进度提示）。
                }
                // 数据安全：切后台/退出时立即落盘对话，防止 500ms 防抖窗口内强杀 App 丢消息
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active {
                        chatStore.flushSave()
                    }
                }
                // ⚠️ 内存告警：CosyVoice3 的引擎常驻约 1.2GB，机器本来就紧。
                // 用户反馈「有一次还卡退了」—— 大概率就是系统在内存压力下
                // 把 App 杀掉。这里收到告警就把引擎卸掉，让它在后台不占内存，
                // 下次朗读时会重新加载（几十秒，但至少不会被杀）。
                // 这不是"优化"，是"别在内存告急时还死守着 1GB"。
                .onReceive(NotificationCenter.default.publisher(
                    for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
                    if ProcessInfo.processInfo.thermalState == .serious
                        || ProcessInfo.processInfo.thermalState == .critical {
                        Task { @MainActor in
                            CosyVoiceTTSManager.shared.unload()
                            TTSService.shared.stop()
                        }
                    }
                }
                // 用原始字符串常量而不是 `UIApplication.lowMemoryNotification`：
                // 后者在某些 SDK 版本里会被重命名成别的名字，而通知名本身是
                // 不变的 "UIApplicationLowMemoryNotification"，用字符串最稳。
                .onReceive(NotificationCenter.default.publisher(
                    for: Notification.Name("UIApplicationLowMemoryNotification"))) { _ in
                    Task { @MainActor in
                        CosyVoiceTTSManager.shared.unload()
                        TTSService.shared.stop()
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
