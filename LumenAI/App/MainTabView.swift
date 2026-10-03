import SwiftUI

// 部署目标 iOS 26.0：TabView 自带液态玻璃外观，
// 滚动时标签栏自动最小化为悬浮胶囊（scroll edge 液态玻璃效果）。
struct MainTabView: View {
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
        // iOS 26+ 滚动时标签栏最小化（部署目标 26.0，API 直接可用；
        // 旧写法 #if swift(>=27.0) 用 Swift 版本判断系统特性，永远不会命中，属死代码）
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
