import Foundation
import UIKit

/// 执行"操作手机"的引擎。
///
/// 能力边界就是产品边界，一开始就写清楚：
///   · 能：打开任意注册了 scheme 的 URL、通过 `shortcuts://run-shortcut?name=` 触发
///     用户已经装好的快捷指令（系统会弹确认）、读写配方、等待。
///   · 不能：合成触摸、给别的 App 输入文字、点系统弹窗、截取整机屏幕。
///     这些需要 backboardd/IOHID 级特权，普通 App 拿不到；这类动作交给快捷指令，
///     或由 Agent 实时指导用户完成。
@MainActor
enum ShortcutEngine {

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
        // 全部动作统一走 execute()：状态机、指标、能力门控只有一份实现，
        // 配方执行与单步执行看到的回执格式完全一致（否则会出现两套成功判定）。
        for (i, step) in recipe.actions.enumerated() {
            let tag = "[\(i + 1)/\(recipe.actions.count)] "
            if case .note(let text) = step {
                lines.append(tag + "注：" + text)
                continue
            }
            guard let action = computerAction(from: step) else {
                lines.append(tag + "跳过：无法识别的配方步骤")
                continue
            }
            let r = await execute(action, attempt: 1)
            lines.append(tag + r.action + " → " + r.status.rawValue + "：" + r.detail)
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
        lines.append("- 合成触摸/输入：**已移除**。合成点击需要 IOHID 级特权，"
                     + "普通构建不具备；交互请用快捷指令，或由 Agent 实时指导用户完成。")

        // 2) 已装配方
        let count = ShortcutStore.shared.recipes.count
        lines.append("- 已保存配方：\(count) 条")
        return lines.joined(separator: "\n")
    }

    // MARK: - 能力（capability-first：先问能不能，再谈做不做）

    /// 当前构建 + 当前设备的能力矩阵（每次现算：scheme 可用性可能变）。
    static func capabilities() async -> [ComputerCapability] {
        let shortcutsOK = UIApplication.shared.canOpenURL(
            URL(string: "shortcuts://run-shortcut?name=probe") ?? URL(string: "shortcuts://x")!)
        return ComputerCapabilityMatrix.make(shortcutsAvailable: shortcutsOK)
    }

    /// 能力矩阵的可读文本（进 probe 报告，也进云端 environmentSection 的素材）。
    static func capabilityText(_ caps: [ComputerCapability]? = nil) async -> String {
        let list: [ComputerCapability]
        if let caps { list = caps } else { list = await capabilities() }
        return list.map { "  - \($0.line)" }.joined(separator: "\n")
    }

    // MARK: - 配方动作 → 计算机动作

    /// `ShortcutRecipe.Action`（用户可编辑的配方行）→ `ComputerAction`（能力/状态机里的动作）。
    /// 转换放在这里而不是 `ComputerAction.swift`：后者必须保持纯 Foundation，
    /// 才能被单独编译出来测。`.note` 是纯注释，没有对应动作，返回 nil 由调用方单独成行。
    static func computerAction(from a: ShortcutRecipe.Action) -> ComputerAction? {
        switch a {
        case .runShortcut(let name): return .runShortcut(name)
        case .openURL(let raw): return .openURL(raw)
        case .wait(let seconds): return .wait(milliseconds: Int(seconds * 1000))
        case .note: return nil
        }
    }

    // MARK: - 单步执行（capability 门控 → 执行 → 验证 → 回执）

    /// 步骤级指标（§13：action/verify/retry/unsupported 都要能量出来）。
    /// 显式标 @MainActor：引擎整体是 MainActor 隔离的，但静态存储属性在 Swift 6 下
    /// 需要显式标注才被认定为隔离（否则报"非隔离的全局可变状态"）。
    @MainActor static var metrics = ComputerStepMetrics()

    @MainActor static func resetMetrics() { metrics = ComputerStepMetrics() }

    /// 执行一个动作并返回结构化回执。**这是整套能力的唯一出口**：
    /// 不支持的动作在这里就被挡掉（unsupported），永远不会走到"假装执行"。
    static func execute(_ action: ComputerAction, attempt: Int = 1) async -> ComputerActionResult {
        let caps = await capabilities()
        guard let cap = ComputerCapabilityMatrix.capability(action.kind, in: caps) else {
            let r = ComputerActionResult.unsupported(kind: action.kind,
                                                     reason: "未知动作类别，拒绝执行", attempt: attempt)
            metrics.record(r)
            return r
        }
        guard cap.status.isAttemptable else {
            let r = ComputerActionResult.unsupported(kind: action.kind, reason: cap.reason,
                                                     attempt: attempt)
            metrics.record(r)
            return r
        }

        let start = Date()
        let elapsed = { Int(Date().timeIntervalSince(start) * 1000) }
        var r: ComputerActionResult

        switch action {
        case .wait(let ms):
            let bounded = min(max(ms, 0), 30_000)   // 上限 30s：防止模型传一个 10 分钟的等待把 run 卡死
            try? await Task.sleep(nanoseconds: UInt64(bounded) * 1_000_000)
            r = .executed(kind: .wait, action: action.label,
                          detail: "已等待 \(bounded)ms", verified: true,
                          verifyDetail: "本地定时器回调到达（等待类动作的完成本身就是验证）",
                          attempt: attempt, elapsedMs: elapsed())

        case .openURL(let raw):
            guard let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty else {
                r = .failed(kind: .openURL, action: action.label,
                            reason: "不是合法 URL（\(raw)）", attempt: attempt, elapsedMs: elapsed())
                break
            }
            let ok = await openURL(url)
            r = ok
                ? .executed(kind: .openURL, action: action.label, detail: "系统接受了 \(raw)",
                            verified: false, verifyDetail: await noVerifyReason(),
                            attempt: attempt, elapsedMs: elapsed())
                : .failed(kind: .openURL, action: action.label,
                          reason: "系统拒绝打开（scheme 未注册或被策略禁止）",
                          attempt: attempt, elapsedMs: elapsed())

        case .openApp(let name):
            // iOS 没有"按名字启动任意 App"的公共 API。可行的只有两条：
            //   1) 该 App 注册了自己的 URL scheme（名字未必等于 App 名，所以这是**尽力而为**）；
            //   2) 用户自建一条快捷指令去打开它（用 runShortcut 调用）。
            // 两条都只有"系统接受"的回执，没有"App 真起来了"的证据。
            let scheme = name.lowercased().replacingOccurrences(of: " ", with: "")
            guard let url = URL(string: "\(scheme)://"), let _ = url.scheme else {
                r = .failed(kind: .openApp, action: action.label,
                            reason: "名字无法转成 URL scheme", attempt: attempt, elapsedMs: elapsed())
                break
            }
            let ok = await openURL(url)
            r = ok
                ? .executed(kind: .openApp, action: action.label,
                            detail: "系统接受了 \(scheme):// （仅当该 App 注册了同名 scheme 才会真的打开）",
                            verified: false, verifyDetail: await noVerifyReason(),
                            attempt: attempt, elapsedMs: elapsed())
                : .failed(kind: .openApp, action: action.label,
                          reason: "\(name) 没有可识别的 URL scheme。请让用户建一条「打开 \(name)」"
                            + "快捷指令，再用 run_shortcut 调它 —— 这是普通 iOS 上唯一可靠的做法",
                          attempt: attempt, elapsedMs: elapsed())

        case .runShortcut(let name):
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&+=")
            let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            guard let url = URL(string: "shortcuts://run-shortcut?name=\(encoded)") else {
                r = .failed(kind: .runShortcut, action: action.label,
                            reason: "快捷指令名无法编码", attempt: attempt, elapsedMs: elapsed())
                break
            }
            let ok = await openURL(url)
            r = ok
                ? .executed(kind: .runShortcut, action: action.label,
                            detail: "已请求系统运行「\(name)」：只代表系统接受，"
                              + "快捷指令可能弹确认且跑完无回执",
                            verified: false, verifyDetail: await noVerifyReason(),
                            attempt: attempt, elapsedMs: elapsed())
                : .failed(kind: .runShortcut, action: action.label,
                          reason: "系统拒绝 shortcuts://（未装快捷指令 App 或未声明 scheme）",
                          attempt: attempt, elapsedMs: elapsed())

        case .screenshot:
            // capability 门控已经挡住，走到这里说明矩阵有 bug —— 仍然如实报 unsupported。
            r = .unsupported(kind: .screenshot,
                             reason: "iOS 无整机截屏公共 API（门控漏过了这一项）", attempt: attempt)
        }

        // 验证阶段（§9）：先等 UI 稳定，再看有没有验证源。
        if r.executed, r.status == .executedUnverified, cap.verify == .probe, action.kind != .wait {
            try? await Task.sleep(nanoseconds: UInt64(ComputerRetryPolicy.default.settleMs) * 1_000_000)
        }

        metrics.record(r)
        return r
    }

    /// 当前为什么无法验证（原样写进 detail，模型据此必须说"执行了但没验证"）。
    private static func noVerifyReason() async -> String {
        "screenshot=unsupported，本机没有屏幕状态可比对，无法自动验证动作是否生效"
    }
}
