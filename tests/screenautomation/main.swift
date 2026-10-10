import Foundation

// ScreenAutomation 纯逻辑（能力矩阵 / 结果状态机 / 重试策略 / 指标）的单元验证。
// 只依赖 Foundation，可单独 swiftc 编译运行，不需要模拟器：
//
//   swiftc -o /tmp/sa_tests \
//       LumenAI/Services/ScreenAutomation/ComputerAction.swift \
//       Tests/screenautomation/main.swift && /tmp/sa_tests
//
// 核心是三条"不许假成功"的不变量（case 3-6），它们是验收底线。
// 合成触摸（tap/swipe/type）已整体移除，动作集合只剩 URL / 快捷指令 / 等待。

var failures = 0
func check(_ name: String, _ cond: Bool, _ extra: String = "") {
    if cond { print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ \(name) \(extra)") }
}

print("== 1. 能力矩阵（普通 iOS 构建） ==")
do {
    let caps = ComputerCapabilityMatrix.make(shortcutsAvailable: true)
    func st(_ k: ComputerActionKind) -> ComputerCapabilityStatus? {
        ComputerCapabilityMatrix.capability(k, in: caps)?.status
    }
    check("screenshot = unsupported（iOS 无整机截屏公共 API）",
          st(.screenshot) == .unsupported, "\(st(.screenshot)!)")
    check("wait = supported", st(.wait) == .supported)
    check("open_url = supported", st(.openURL) == .supported)
    check("open_app = restricted（要 scheme 或用户自建快捷指令）", st(.openApp) == .restricted)
    check("run_shortcut = supported（scheme 可用）", st(.runShortcut) == .supported)
    check("只有 supported/restricted 值得尝试",
          caps.filter { $0.status.isAttemptable }.map(\.kind.rawValue).sorted()
              == ["open_app", "open_url", "run_shortcut", "wait"],
          "\(caps.filter { $0.status.isAttemptable }.map { $0.kind.rawValue })")
    check("不再有 tap/swipe/type 这三类能力",
          !ComputerActionKind.allCases.map(\.rawValue).contains("tap")
              && !ComputerActionKind.allCases.map(\.rawValue).contains("swipe")
              && !ComputerActionKind.allCases.map(\.rawValue).contains("type"))
}

print("== 2. shortcuts:// 不可用时降级 ==")
do {
    check("scheme 不可用 → run_shortcut = restricted",
          ComputerCapabilityMatrix.capability(
            .runShortcut,
            in: ComputerCapabilityMatrix.make(shortcutsAvailable: false))?.status == .restricted)
}

print("== 3. 不许假成功：unsupported 的不变量 ==")
do {
    let r = ComputerActionResult.unsupported(kind: .screenshot, reason: "iOS 无整机截屏公共 API")
    check("executed = false", !r.executed)
    check("verified = false", !r.verified)
    check("status = unsupported", r.status == .unsupported)
    check("invariant 成立", r.invariantHolds)
    check("status 不是 success", !r.status.isSuccess)
    let json = r.jsonString
    check("JSON 含 requested/executed/verified/status",
          json.contains("\"requested\":true") && json.contains("\"executed\":false")
              && json.contains("\"verified\":false") && json.contains("\"status\":\"unsupported\""),
          json)
}

print("== 4. 执行了但没验证 ≠ 成功 ==")
do {
    let r = ComputerActionResult.executed(kind: .runShortcut, action: "run_shortcut(x)",
                                          detail: "系统接受了 URL", verified: false)
    check("status = executed_unverified", r.status == .executedUnverified, r.status.rawValue)
    check("executed = true", r.executed)
    check("verified = false", !r.verified)
    check("不许算 success", !r.status.isSuccess)
    check("detail 里写明未验证", r.detail.contains("未验证"), r.detail)
    check("invariant 成立", r.invariantHolds)
}

print("== 5. 真验证过才算 success ==")
do {
    let r = ComputerActionResult.executed(kind: .wait, action: "wait(600)",
                                          detail: "已等待 600ms", verified: true,
                                          verifyDetail: "定时器回调到达")
    check("executed + verified → success", r.status == .success && r.status.isSuccess)
    check("invariant 成立", r.invariantHolds)
    let v = ComputerActionResult.verificationFailed(kind: .openURL, action: "open_url(x)",
                                                    detail: "目标页面未出现")
    check("验证失败 → verification_failed", v.status == .verificationFailed)
    check("验证失败不能是 success", !v.status.isSuccess)
    check("验证失败 invariant 成立", v.invariantHolds)
}

print("== 6. failed / timeout 的不变量 ==")
do {
    let f = ComputerActionResult.failed(kind: .openURL, action: "open_url(x)",
                                        reason: "系统拒绝")
    let t = ComputerActionResult.timeout(kind: .runShortcut, action: "run_shortcut(x)",
                                         reason: "15000ms 内无回执")
    check("failed 未执行未验证", !f.executed && !f.verified && f.status == .failed && f.invariantHolds)
    check("timeout 未执行未验证", !t.executed && !t.verified && t.status == .timeout && t.invariantHolds)
    check("failed 不是 success", !f.status.isSuccess && !t.status.isSuccess)
}

print("== 7. 重试 / 超时策略（不许无限循环） ==")
do {
    let p = ComputerRetryPolicy.default
    check("maxRetries = 2", p.maxRetries == 2)
    check("第 1 次失败后允许重试", p.shouldRetry(afterAttempt: 1))
    check("第 2 次失败后允许重试", p.shouldRetry(afterAttempt: 2))
    check("第 3 次失败后停止", !p.shouldRetry(afterAttempt: 3))
    check("已试 2 次还能给第 3 次", p.nextAttempt(attemptsDone: 2) == 3)
    check("已试 3 次不再给下一次", p.nextAttempt(attemptsDone: 3) == nil)
    check("置信度阈值 0...1", p.confidenceThreshold > 0 && p.confidenceThreshold < 1)
}

print("== 8. 动作标签映射 ==")
do {
    check("open_app kind 映射", ComputerAction.openApp(name: "Safari").kind == .openApp)
    check("open_url kind 映射", ComputerAction.openURL("https://x").kind == .openURL)
    check("run_shortcut kind 映射", ComputerAction.runShortcut("X").kind == .runShortcut)
    check("wait kind 映射", ComputerAction.wait(milliseconds: 100).kind == .wait)
    check("screenshot kind 映射", ComputerAction.screenshot.kind == .screenshot)
    check("所有 kind 都有 opName", ComputerActionKind.allCases.allSatisfy { !$0.opName.isEmpty })
}

print("== 9. 步骤指标 ==")
do {
    var m = ComputerStepMetrics()
    m.record(.unsupported(kind: .screenshot, reason: "x", elapsedMs: 0))
    m.record(.executed(kind: .wait, action: "wait", detail: "ok", verified: true,
                       elapsedMs: 120, verifyElapsedMs: 5))
    m.record(.executed(kind: .runShortcut, action: "run", detail: "ok", verified: false,
                       attempt: 2, elapsedMs: 80))
    check("actionCount = 3", m.actionCount == 3, "\(m.actionCount)")
    check("unsupported 计数 = 1", m.unsupportedCount == 1)
    check("retry 计数 = 1（attempt 2）", m.retryCount == 1, "\(m.retryCount)")
    check("verify 计数 = 1（有 verify 耗时的那次）", m.verifyCount == 1, "\(m.verifyCount)")
    check("avgAction = (0+120+80)/3 = 66", m.avgActionMs == 66, "\(m.avgActionMs)")
    check("status 分布含 unsupported", (m.statusCounts["unsupported"] ?? 0) == 1)
    check("summary 不为空", !m.summaryLine.isEmpty, m.summaryLine)
}

print()
if failures == 0 { print("✅ 全部 ScreenAutomation 测试通过") }
else { print("❌ \(failures) 项失败") }
exit(failures == 0 ? 0 : 1)
