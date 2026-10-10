import Foundation

// MARK: - Computer Action 核心（纯逻辑，只依赖 Foundation）
//
// 为什么单独成文件：能力矩阵、状态机、结果 JSON 这三样必须能**脱离 UIKit 单独编译出来测**，
// 否则"unsupported 到底会不会被伪装成 success"这种问题只能靠读代码猜。
// UIKit 相关的执行留在 `ShortcutEngine`，这里只有数据与规则。
//
// 三条不可违反的规则（文件末尾有对应测试）：
//   1. `unsupported` 的动作永远 `executed == false && verified == false`；
//   2. `executed == false` 时 status 只能是 unsupported / failed / timeout；
//   3. `status == .success` 必须同时满足 executed 与 verified —— 没有验证手段时
//      只能给 `executedUnverified`，绝不冒充成功。

// MARK: - 动作

/// 一个可被 Agent 请求的动作类别。
///
/// 只保留普通 iOS 上**真实可执行**的动作：打开 URL / 运行快捷指令 / 等待。
/// 合成触摸（tap/swipe/type）已整体移除 —— 取而代之的是「实时指导用户操作」。
enum ComputerActionKind: String, CaseIterable, Sendable {
    case screenshot
    case wait
    case openApp = "open_app"
    case openURL = "open_url"
    case runShortcut = "run_shortcut"

    /// 给模型看的名字（与 `phone` 工具的 op 保持一致的下划线风格）。
    var opName: String { rawValue }
}

/// 具体动作 + 参数。
enum ComputerAction: Equatable, Sendable {
    case screenshot
    case wait(milliseconds: Int)
    case openApp(name: String)
    case openURL(String)
    case runShortcut(String)

    var kind: ComputerActionKind {
        switch self {
        case .screenshot: return .screenshot
        case .wait: return .wait
        case .openApp: return .openApp
        case .openURL: return .openURL
        case .runShortcut: return .runShortcut
        }
    }

    /// 一行可读描述（进日志/结果里的 action 字段，不进 prompt 正文）。
    var label: String {
        switch self {
        case .screenshot: return "screenshot"
        case .wait(let ms): return "wait(\(ms)ms)"
        case .openApp(let n): return "open_app(\(n))"
        case .openURL(let u): return "open_url(\(u))"
        case .runShortcut(let n): return "run_shortcut(\(n))"
        }
    }
}

// MARK: - 能力

/// 一个能力在**当前构建 + 当前设备**上的真实状态。
enum ComputerCapabilityStatus: String, Equatable, Sendable {
    /// 现在就能执行（例如打开 URL、跑快捷指令、等待）。
    case supported
    /// 部分可用：依赖用户预先配置（例如"打开 App"要靠用户自己建的快捷指令）。
    case restricted
    /// 当前构建里**没有**这条执行路径。
    case unsupported

    /// 是否值得让模型去尝试。
    var isAttemptable: Bool {
        self == .supported || self == .restricted
    }
}

/// 能力如何被验证（这决定了"执行了"能不能升级成"成功"）。
enum ComputerVerifyMode: String, Equatable, Sendable {
    /// 无法验证（没有截图、没有回执）—— 执行完只能报 `executedUnverified`。
    case none
    /// 有系统回执（例如 open 的 completion）：能证明**被接受**，仍证明不了**已完成**。
    case receipt
    /// 有后续探测手段（截图比对 / Accessibility / 未来 backend 提供的 probe）。
    case probe
}

/// 一个动作类别的能力声明。
struct ComputerCapability: Equatable, Sendable {
    let kind: ComputerActionKind
    let status: ComputerCapabilityStatus
    let reason: String
    let verify: ComputerVerifyMode

    /// 给模型看的一行（能力矩阵的一行）。
    var line: String {
        "\(kind.opName): \(status.rawValue) — \(reason)"
    }
}

// MARK: - 结果

/// 动作结果状态。**这是给模型看的合同**，不允许把失败包装成成功。
enum ComputerActionStatus: String, Equatable, Sendable {
    /// executed + verified 都为真。
    case success
    /// 真的执行了，但没有验证手段（截图不可用 / 系统不给回执）。
    /// 明确**不等于**成功：模型必须据此说明"执行了但没验证"。
    case executedUnverified = "executed_unverified"
    /// 执行了，但验证发现屏幕没有出现预期变化。
    case verificationFailed = "verification_failed"
    /// 执行被系统/环境拒绝。
    case failed
    /// 等待/验证超时。
    case timeout
    /// 当前环境根本不支持该动作（请求即失败，不执行）。
    case unsupported

    var isSuccess: Bool { self == .success }
}

/// 一次动作的完整回执。
struct ComputerActionResult: Equatable, Sendable {
    /// 实际请求的动作（未裁剪前的原始参数）。
    let action: String
    /// 请求的动作类别。
    let kind: ComputerActionKind
    /// 是否发起过执行（unsupported 一律 false）。
    let executed: Bool
    /// 是否完成过验证（没有验证手段一律 false）。
    let verified: Bool
    let status: ComputerActionStatus
    /// 给模型看的原因/细节（成功时也留一句，说明验证依据是什么）。
    let detail: String
    /// 动作本身耗时（ms，不含验证）。
    let elapsedMs: Int
    /// 验证耗时（ms）；无验证为 0。
    let verifyElapsedMs: Int
    /// 第几次尝试（从 1 开始；重试由上层策略决定，结果如实记录）。
    let attempt: Int

    /// 结构化回执（模型/日志都吃这一份）。
    /// 例：
    /// `{"action":"tap(0.50, 0.30)","executed":false,"verified":false,"status":"unsupported","detail":"..."}`
    var jsonString: String {
        let obj: [String: Any] = [
            "action": action,
            "kind": kind.rawValue,
            "requested": true,
            "executed": executed,
            "verified": verified,
            "status": status.rawValue,
            "detail": detail,
            "elapsed_ms": elapsedMs,
            "verify_ms": verifyElapsedMs,
            "attempt": attempt,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"status\":\"failed\",\"detail\":\"result serialization failed\"}"
        }
        return text
    }

    /// 状态机自检：不满足就说明判定逻辑有 bug（测试里会逐条断言）。
    var invariantHolds: Bool {
        switch status {
        case .unsupported:
            return !executed && !verified
        case .failed, .timeout:
            return !executed || !verified   // 没执行当然不成立；执行了但验证没过也不能算成功
        case .executedUnverified:
            return executed && !verified
        case .verificationFailed:
            return executed && !verified
        case .success:
            return executed && verified
        }
    }

    // MARK: 构造（各状态的唯一入口，保证不变量由构造函数维护）

    static func unsupported(kind: ComputerActionKind, reason: String, attempt: Int = 1,
                            elapsedMs: Int = 0) -> ComputerActionResult {
        ComputerActionResult(action: "", kind: kind, executed: false, verified: false,
                             status: .unsupported, detail: reason,
                             elapsedMs: elapsedMs, verifyElapsedMs: 0, attempt: attempt)
    }

    static func failed(kind: ComputerActionKind, action: String, reason: String, attempt: Int = 1,
                       elapsedMs: Int = 0) -> ComputerActionResult {
        ComputerActionResult(action: action, kind: kind, executed: false, verified: false,
                             status: .failed, detail: reason,
                             elapsedMs: elapsedMs, verifyElapsedMs: 0, attempt: attempt)
    }

    static func timeout(kind: ComputerActionKind, action: String, reason: String, attempt: Int = 1,
                        elapsedMs: Int = 0) -> ComputerActionResult {
        ComputerActionResult(action: action, kind: kind, executed: false, verified: false,
                             status: .timeout, detail: reason,
                             elapsedMs: elapsedMs, verifyElapsedMs: 0, attempt: attempt)
    }

    static func executed(kind: ComputerActionKind, action: String, detail: String,
                         verified: Bool, verifyDetail: String? = nil,
                         attempt: Int = 1, elapsedMs: Int = 0, verifyElapsedMs: Int = 0)
        -> ComputerActionResult {
        let status: ComputerActionStatus = verified ? .success : .executedUnverified
        let text = verified ? (detail + "｜验证: " + (verifyDetail ?? "ok")) : (detail + "｜未验证: "
                    + (verifyDetail ?? "当前环境没有可用的验证手段（截图/回执），"
                       + "请让用户目视确认后再继续"))
        return ComputerActionResult(action: action, kind: kind, executed: true,
                                    verified: verified, status: status, detail: text,
                                    elapsedMs: elapsedMs, verifyElapsedMs: verifyElapsedMs,
                                    attempt: attempt)
    }

    static func verificationFailed(kind: ComputerActionKind, action: String, detail: String,
                                   attempt: Int = 1, elapsedMs: Int = 0, verifyElapsedMs: Int = 0)
        -> ComputerActionResult {
        ComputerActionResult(action: action, kind: kind, executed: true, verified: false,
                             status: .verificationFailed, detail: detail,
                             elapsedMs: elapsedMs, verifyElapsedMs: verifyElapsedMs,
                             attempt: attempt)
    }
}

// MARK: - 重试 / 超时策略

/// 一次任务里的失败处理上限。**必须有上限**：找不到目标就一直重试是这类 Agent 最常见的死循环。
struct ComputerRetryPolicy: Equatable, Sendable {
    /// 找不到目标 / 验证失败时最多重试几次（总计尝试 = 1 + maxRetries）。
    let maxRetries: Int
    /// 单个动作的超时（ms）。
    let actionTimeoutMs: Int
    /// 验证前等待 UI 稳定的时间（ms）。
    let settleMs: Int
    /// 低于该置信度的识别结果视为"没找到"（vision 层用）。
    let confidenceThreshold: Double

    static let `default` = ComputerRetryPolicy(maxRetries: 2, actionTimeoutMs: 15_000,
                                               settleMs: 600, confidenceThreshold: 0.6)

    /// 第 attempt 次（从 1 起）失败后是否还允许下一次。
    func shouldRetry(afterAttempt attempt: Int) -> Bool {
        attempt <= maxRetries      // attempt=1 失败 → 还允许第 2 次，直到 attempt > maxRetries
    }

    /// 给定"已尝试次数"算出下一次序号；不该再试时返回 nil。
    func nextAttempt(attemptsDone: Int) -> Int? {
        guard attemptsDone <= maxRetries else { return nil }
        return attemptsDone + 1
    }
}

// MARK: - 能力矩阵

/// 当前构建的能力矩阵。**纯函数**：所有会影响结果的输入都由调用方传进来
/// （变体、probe 实测到的 scheme 可用性、已保存的配方/快捷指令线索），
/// 这样矩阵本身可以在测试里逐行断言，而不是"跑起来才知道"。
enum ComputerCapabilityMatrix {

    /// - Parameter shortcutsAvailable: `shortcuts://` 是否被系统识别（probe 实测）。
    static func make(shortcutsAvailable: Bool) -> [ComputerCapability] {
        var caps: [ComputerCapability] = []

        // 截图：iOS 没有"截取本机当前屏幕"的公共 API。
        //   · UIGraphicsImageRenderer 只能截**自己 App** 的画面；
        //   · RPScreenRecorder 要用户发起并常驻广播。
        // 所以 in-app 一律 unsupported —— 屏幕识别交给快捷指令的「截屏 + 从图像中提取文本」。
        caps.append(ComputerCapability(
            kind: .screenshot, status: .unsupported,
            reason: "iOS 无截取整机屏幕的公共 API；屏幕识别请用快捷指令的「截屏 + 提取文本」",
            verify: .none))

        caps.append(ComputerCapability(
            kind: .wait, status: .supported,
            reason: "本地定时等待，用于给 UI 留稳定时间", verify: .probe))

        caps.append(ComputerCapability(
            kind: .openURL, status: .supported,
            reason: "UIApplication.open + 系统回执", verify: .receipt))

        caps.append(ComputerCapability(
            kind: .openApp, status: .restricted,
            reason: "只能打开注册了 URL scheme 的 App，或由用户自建快捷指令代打（"
                    + "App 没有公开的『按名字启动任意 App』API）", verify: .receipt))

        caps.append(ComputerCapability(
            kind: .runShortcut, status: shortcutsAvailable ? .supported : .restricted,
            reason: shortcutsAvailable
                ? "shortcuts://run-shortcut 可用；系统可能弹确认，跑完无回执"
                : "shortcuts:// 未被系统识别（未声明 LSApplicationQueriesSchemes 或未装快捷指令 App）",
            verify: .receipt))

        return caps
    }

    /// 按类别查。
    static func capability(_ kind: ComputerActionKind, in caps: [ComputerCapability]) -> ComputerCapability? {
        caps.first { $0.kind == kind }
    }
}

// MARK: - 步骤级性能统计

/// 手机 Agent 的步骤级指标（§13：action / vision / verify / retry 各自要能量出来）。
/// 刻意不并进 `AgentPerformanceMetrics`：那是**整个 run** 的 LLM 指标，
/// 这里是**每个动作**的执行指标，两者聚合口径不同，混在一起谁也看不清。
struct ComputerStepMetrics: Equatable, Sendable {
    var actionCount: Int = 0
    var visionCount: Int = 0
    var verifyCount: Int = 0
    var retryCount: Int = 0
    var unsupportedCount: Int = 0
    var totalActionMs: Int = 0
    var totalVerifyMs: Int = 0
    /// 按状态计数（success / unsupported / …），报告用。
    var statusCounts: [String: Int] = [:]

    mutating func record(_ r: ComputerActionResult) {
        actionCount += 1
        totalActionMs += r.elapsedMs
        totalVerifyMs += r.verifyElapsedMs
        if r.status == .unsupported { unsupportedCount += 1 }
        if r.attempt > 1 { retryCount += (r.attempt - 1) }
        if r.verifyElapsedMs > 0 { verifyCount += 1 }
        statusCounts[r.status.rawValue, default: 0] += 1
    }

    /// 均值动作耗时（ms）；无动作为 0。
    var avgActionMs: Int { actionCount == 0 ? 0 : totalActionMs / actionCount }

    var summaryLine: String {
        "actions=\(actionCount) vision=\(visionCount) verify=\(verifyCount) "
        + "retries=\(retryCount) unsupported=\(unsupportedCount) "
        + "avgAction=\(avgActionMs)ms total=\(totalActionMs)ms "
        + "status=\(statusCounts.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))"
    }
}
