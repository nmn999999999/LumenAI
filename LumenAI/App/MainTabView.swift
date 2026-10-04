import SwiftUI

// 部署目标 iOS 26.0：TabView 自带液态玻璃外观，
// 滚动时标签栏自动最小化为悬浮胶囊（scroll edge 液态玻璃效果）。
struct MainTabView: View {
    /// 审批中心（全局单例）。观察它以驱动 create_plugin 安装确认卡，
    /// 该卡是 App 级 UI：用户在任意 tab 都能批准 AI 生成的插件。
    @ObservedObject private var approvalCenter = AgentApprovalCenter.shared

    var body: some View {
        TabView {
            ChatView()
                .tabItem {
                    Label(t("聊天"), systemImage: "bubble.left.and.bubble.right.fill")
                }

            ModelListView()
                .tabItem {
                    Label(t("模型"), systemImage: "cpu.fill")
                }

            FilesView()
                .tabItem {
                    Label(t("文件"), systemImage: "folder.fill")
                }

            ProvidersView()
                .tabItem {
                    Label(t("服务"), systemImage: "server.rack")
                }

            SettingsView()
                .tabItem {
                    Label(t("设置"), systemImage: "gearshape.fill")
                }
        }
        // create_plugin 安装卡的根层挂载点（零尺寸，不影响布局）
        .overlay(PluginInstallSheetAnchor(item: $approvalCenter.pendingInstallCall))
        // iOS 26+ 滚动时标签栏最小化（部署目标 26.0，API 直接可用；
        // 旧写法 #if swift(>=27.0) 用 Swift 版本判断系统特性，永远不会命中，属死代码）
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
