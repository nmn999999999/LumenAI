import Foundation
import SwiftUI

/// 全局主题色系统：包含 light/dark 模式选择 + 4 套强调色搭配(系统 / 海洋 / 森林 / 落日)。
/// 通过 `@AppStorage` 持久化在 UserDefaults,即开即用无须迁移。
enum AppTheme: String, CaseIterable, Codable, Sendable {
    case system
    case ocean
    case forest
    case sunset
    case midnight

    var displayName: String {
        switch self {
        case .system:   return "跟随系统"
        case .ocean:    return "海洋蓝"
        case .forest:   return "森林绿"
        case .sunset:   return "落日橙"
        case .midnight: return "暗夜紫"
        }
    }

    /// 主题色被 SwiftUI tint 系统采用,影响按钮/链接/progress 等强调元素。
    var accentColor: Color {
        switch self {
        case .system:   return .accentColor
        case .ocean:    return Color(red: 0.0,  green: 0.47, blue: 0.84)  // 海洋蓝
        case .forest:   return Color(red: 0.20, green: 0.55, blue: 0.30)  // 森林绿
        case .sunset:   return Color(red: 0.95, green: 0.45, blue: 0.20)  // 落日橙
        case .midnight: return Color(red: 0.45, green: 0.30, blue: 0.85)  // 暗夜紫
        }
    }

    /// 气泡背景色：亮色调柔白 / 暗色调深灰微蓝,跟主色系保持统一感。
    var bubbleBackgroundLight: Color {
        switch self {
        case .system:   return Color(.systemBackground)
        case .ocean:    return Color(red: 0.96, green: 0.98, blue: 1.00)
        case .forest:   return Color(red: 0.97, green: 0.99, blue: 0.96)
        case .sunset:   return Color(red: 1.00, green: 0.97, blue: 0.94)
        case .midnight: return Color(red: 0.97, green: 0.96, blue: 1.00)
        }
    }

    var bubbleBackgroundDark: Color {
        switch self {
        case .system:   return Color(red: 0.10, green: 0.10, blue: 0.12)
        case .ocean:    return Color(red: 0.05, green: 0.10, blue: 0.18)
        case .forest:   return Color(red: 0.06, green: 0.12, blue: 0.08)
        case .sunset:   return Color(red: 0.14, green: 0.10, blue: 0.06)
        case .midnight: return Color(red: 0.10, green: 0.08, blue: 0.18)
        }
    }

    /// 强制 light/dark 模式（nil = 跟随系统）
    var preferredColorScheme: ColorScheme? {
        nil  // 跟随系统；如需扩展"强制亮/强制暗"再加 case
    }

    /// 页面底色的基底（不透明纯色）。渐变与窗口兜底背景共用它，
    /// 保证「页面内」与「推出去的子页面」看到的是同一套底色。
    func pageBase(for scheme: ColorScheme) -> Color {
        scheme == .dark ? bubbleBackgroundDark : bubbleBackgroundLight
    }

    /// 页面渐变的色标：基底 → 基底 → 主题强调色。
    /// 窗口兜底背景（AppBackdrop）与页面背景共用同一组色标，两层不会对不上。
    func pageColors(for scheme: ColorScheme) -> [Color] {
        let base = pageBase(for: scheme)
        let accent = accentColor.opacity(scheme == .dark ? 0.30 : 0.22)
        return [base, base, accent]
    }

    /// 页面背景：在基底色上叠一层向右下渐隐的主题色，让毛玻璃卡片、
    /// 列表行间隙、滚动边缘高光透得出层次（纯色背景会把这些全部盖死，
    /// 玻璃只剩一层灰）。原来这里是纯色（REVIEW m4），玻璃化后改成渐变。
    func pageBackground(for scheme: ColorScheme) -> LinearGradient {
        LinearGradient(
            colors: pageColors(for: scheme),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

/// `@AppStorage` 包装：避免每次访问读 UserDefaults,集中一处修改入口。
struct ThemeStore {
    @AppStorage("appTheme") private(set) var raw: String = AppTheme.system.rawValue

    var current: AppTheme {
        get { AppTheme(rawValue: raw) ?? .system }
        nonmutating set { raw = newValue.rawValue }
    }
}
