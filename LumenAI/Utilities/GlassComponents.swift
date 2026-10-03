import SwiftUI

// Liquid Glass 组件库（需要 Xcode 26+ SDK，iOS 26+）
// 参考: https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views

struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = 24
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 24) -> some View {
        padding(16)
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}

struct GlassIconButton: View {
    let systemImage: String
    var label: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                if let label {
                    Text(label)
                }
            }
        }
        .buttonStyle(.glass)
        .labelStyle(.titleAndIcon)
    }
}

struct SectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            Text(title)
                .font(.headline)
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
    }
}

struct ModelBadge: View {
    let text: String
    var tint: Color = .blue

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.15), in: Capsule())
            .foregroundStyle(tint)
    }
}

// MARK: - 统一的轻提示（toast）

/// 页面底部弹出的轻提示胶囊。
///
/// 为什么统一：这段样式在三个地方各抄了一遍（服务页 / 模块页 / 设置页的 S3 备份），
/// 而且三份**并不一样** —— 设置页那份没有自动消失也没有动画，「恢复成功」会一直挂在
/// 屏幕上，直到用户触发下一个动作才被换掉。复制粘贴的代价不是"多写了几行"，
/// 而是"其中一份漏掉了行为，而且没人会发现"。
/// 现在样式、动效、自动消失都只有一处定义。
struct ToastModifier: ViewModifier {
    @Binding var message: String?
    /// 停留时长。2.2 秒沿用了原来两处各写一遍的值（`2_200_000_000` 纳秒）。
    var duration: Double = 2.2

    /// 每次有新提示就 +1，用作 `.task(id:)` 的身份 —— 换一句话就要重新计时。
    ///
    /// 如实说明一处残留差别：**同一句话在它还显示着的时候被再次触发**，`message`
    /// 的值没变、`onChange` 不触发，计时不会重启，它会比预期早一点消失。
    /// 要修得给调用方加一层"重新触发"的约定（比如传一个 generation），
    /// 而实际使用里这个差别看不出来 —— 不值得为它增加调用负担。
    @State private var token = 0

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                if let message {
                    Text(message)
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: .capsule)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        // 提示是**状态反馈**，不是可操作元素：不加按钮语义，
                        // 但也必须能被 VoiceOver 读到（否则"操作成功了没有"这件事对
                        // 读屏用户完全不可知）。
                        .accessibilityAddTraits(.isStaticText)
                }
            }
            // 动画挂在 overlay 外层而不是每处调用点各写一个 withAnimation：
            // 挂在这里，三处的进出场必然一致。
            .animation(.snappy, value: message)
            .onChange(of: message) { _, newValue in
                if newValue != nil { token += 1 }
            }
            .task(id: token) {
                // token == 0 是首次出现（还没有任何提示），不要无谓地跑一次计时。
                guard token > 0, message != nil else { return }
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                message = nil
            }
    }
}

extension View {
    /// 在页面底部显示一条会自动消失的轻提示。用法：`.toast($toast)`
    func toast(_ message: Binding<String?>, duration: Double = 2.2) -> some View {
        modifier(ToastModifier(message: message, duration: duration))
    }

    /// 滚动到顶/底时显示液态玻璃边缘高光（iOS 26 `scrollEdgeEffectStyle`）。
    /// 所有可滚动界面统一走这里，保证每个页面滚到边缘都有同一套玻璃反馈。
    func glassScrollEdges(_ edges: Edge.Set = [.top, .bottom]) -> some View {
        scrollEdgeEffectStyle(.soft, for: edges)
    }
}

// MARK: - 全局通透背景

/// 垫在 `MainTabView` 后面的浅渐变背景。
///
/// 为什么需要：Material / 玻璃的「通透」是**透出下层**，而 SwiftUI 默认窗口是
/// 一层不透明的 systemBackground —— 底下没有东西可透，玻璃就只剩灰。
/// 垫一层与页面同底色的渐变后，毛玻璃卡片、列表行间隙、滚动边缘高光
/// 才能显出层次；同时 NavigationStack 推出的子页面（详情/编辑页）是透明的，
/// 它们看到的就是这一层 —— 所以底色必须和 `AppTheme.pageBackground` 同源。
struct AppBackdrop: View {
    let colors: [Color]

    var body: some View {
        LinearGradient(
            colors: colors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .background(colors.first ?? .clear)
    }
}
