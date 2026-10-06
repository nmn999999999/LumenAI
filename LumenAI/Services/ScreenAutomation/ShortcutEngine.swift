import Foundation
import UIKit

/// 执行"操作手机"的引擎。
///
/// **合规版**能做到的，和**不能**做到的，必须一开始就写清楚（能力边界就是产品边界）：
///   · 能：打开任意注册了 scheme 的 URL、通过 `shortcuts://run-shortcut?name=` 触发
///     用户已经装好的快捷指令（系统会弹确认）、读写配方。
///   · 不能：绕过系统直接合成触摸、给别的 App 输入文字、点系统弹窗。
///     这些需要 backboardd/IOHID 级别的特权，普通开发者证书拿不到 —— 只有
///     `SIMULATE_TAP` 变体（自签/TrollStore）才有可能，且**能不能用由 probe 实测说了算**。
@MainActor
enum ShortcutEngine {

    enum Variant {
        static var isTapBuild: Bool {
            #if SIMULATE_TAP
            return true
            #else
            return false
            #endif
        }

        static var displayName: String {
            #if SIMULATE_TAP
            return "Tap（自签，含合成触摸代码）"
            #else
            return "合规（仅 URL / 快捷指令）"
            #endif
        }
    }

    // MARK: - 运行

    /// 执行一条配方。返回给模型看的逐条结果（成功/跳过/原因），**不做任何伪装** ——
    /// 跳过的动作必须说清楚为什么，否则模型会向用户报告"已经点过了"。
    static func run(_ recipe: ShortcutRecipe) async -> String {
        var lines: [String] = ["执行「\(recipe.name)」（\(recipe.actions.count) 步）"]
        if recipe.actions.isEmpty {
            // 空配方 = 只有名字。它的真实含义是"去快捷指令 App 跑这条"，
            // 所以按 runShortcut 处理，而不是报错。
            lines.append(await runShortcut(named: recipe.name))
            return lines.joined(separator: "\n")
        }
        for (i, action) in recipe.actions.enumerated() {
            let step = "[\(i + 1)/\(recipe.actions.count)] "
            switch action {
            case .runShortcut(let name):
                let result = await runShortcut(named: name)
                lines.append(step + result)
            case .openURL(let raw):
                let result = await open(raw)
                lines.append(step + result)
            case .wait(let seconds):
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                lines.append(step + "已等待 \(String(format: "%.1f", seconds)) 秒")
            case .note(let text):
                lines.append(step + "注：" + text)
            case .typeText(let text):
                #if SIMULATE_TAP
                lines.append(step + TapBackend.typeText(text))
                #else
                lines.append(step + "跳过：合规版没有系统级输入注入。可在快捷指令里用"
                             + "「输入文本」动作实现，然后把这条改成 run。")
                #endif
            case .tap(let x, let y):
                #if SIMULATE_TAP
                lines.append(step + TapBackend.tap(normalizedX: x, normalizedY: y))
                #else
                lines.append(step + "跳过：合规版不能合成触摸。请把这一步做成快捷指令里的"
                             + "动作，再用 run 执行；或改用 Tap 自签版。")
                #endif
            }
        }
        return lines.joined(separator: "\n")
    }

    /// 通过 URL 触发快捷指令 App 里的一条指令。
    ///
    /// 事实性约束（模型必须知道，否则会以为"调用成功=动作完成"）：
    ///   · `open` 返回 true 只代表**系统接受了这个 URL**，不代表快捷指令跑完了；
    ///   · 快捷指令 App 通常会弹一次确认，需要用户点；
    ///   · 指令不存在 / 没装快捷指令 App 时，系统可能静默无事发生。
    static func runShortcut(named name: String) async -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=")   // 这些必须自己转义，否则名字里带 & 会截断
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        guard let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else {
            return "失败：快捷指令名无法编码（\(name)）"
        }
        let opened = await openURL(url)
        return opened
            ? "已请求系统运行快捷指令「\(name)」。⚠️ 只代表系统接受了请求："
              + "快捷指令 App 可能弹出确认，且它跑完没有回执 —— 不要声称动作已完成，"
              + "请让用户看一眼手机。"
            : "失败：系统拒绝打开 shortcuts://（多半是没装快捷指令 App，"
              + "或本机不允许该 URL scheme）。"
    }

    static func open(_ raw: String) async -> String {
        guard let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty else {
            return "失败：不是合法 URL（\(raw)）"
        }
        let ok = await openURL(url)
        return ok ? "已打开 \(raw)" : "失败：系统拒绝打开 \(raw)（scheme 未注册或被策略禁止）"
    }

    private static func openURL(_ url: URL) async -> Bool {
        // canOpenURL 受 LSApplicationQueriesSchemes 限制：没声明的 scheme 一律返回 false，
        // 这跟"对方 App 在不在"无关，所以不能拿它当唯一判据 —— 直接 open 再看回调。
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { ok in
                continuation.resume(returning: ok)
            }
        }
    }

    // MARK: - 能力探测（**能力以这里的实测为准，不以文档/预期为准**）

    /// 返回一段人类/模型都能读的探测报告。
    ///
    /// 为什么必须有它：这类能力在不同 iOS 版本、不同签名方式下结果完全不同，
    /// 写代码时的"应该可以"没有意义。报告里每一项都必须是**刚刚真的跑过**的结果。
    static func probe() async -> String {
        var lines = ["## 手机操作能力探测"]
        lines.append("变体：\(Variant.displayName)")

        // 1) 快捷指令 URL 能不能被识别
        let shortcutsDeclared: Bool
        if let url = URL(string: "shortcuts://run-shortcut?name=probe") {
            shortcutsDeclared = UIApplication.shared.canOpenURL(url)
        } else {
            shortcutsDeclared = false
        }
        lines.append("""
        - shortcuts:// scheme 可用：\(shortcutsDeclared ? "是" : "否")
          （false 通常意味着未在 LSApplicationQueriesSchemes 声明、或本机没装快捷指令 App；
          真正能不能跑仍以 `phone run` 的 open 回调为准）
        """)

        // 2) 合成触摸
        #if SIMULATE_TAP
        lines.append(contentsOf: TapBackend.probe().map { "- \($0)" })
        #else
        lines.append("- 合成触摸：本变体**未编译**（合规版不包含私有 API 调用）。"
                     + "要测试真机可行性请用 LumenAI-Tap 包。")
        #endif

        // 3) 已装配方
        let count = ShortcutStore.shared.recipes.count
        lines.append("- 已保存配方：\(count) 条")
        return lines.joined(separator: "\n")
    }
}
