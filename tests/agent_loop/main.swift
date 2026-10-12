import Foundation

// Agent 主循环终止行为的回归测试（P0）。
//
// 为什么需要它：用户报的现象是"已经显示 Final Answer，Agent 还在继续循环 / 继续请求模型"。
// 这类 bug 用 UI 断言看不出来 —— 界面上答案确实出来了，多出来的请求发生在后台。
// 所以这里断言的是**模型请求次数、终止原因、返回正文、是否清断点存档**这四件事，
// 它们才是"停没停"的可观测证据。
//
// 驱动的是生产代码本身：`AgentLoopTerminator` / `AgentAnswerSimilarity` / `AgentFinalAnswer`
// （见 LumenAI/Services/AgentPerf/AgentLoopPolicy.swift）—— AgentService.run 里用的就是它们。
// 模拟器只复刻 run() 的**决策顺序**（一轮 = 一次模型请求 → 判定 → 要么结束、要么下一轮），
// 因此任何"终止条件被放松/收紧"的改动都会在这里暴露。
//
// 另外，这里也是 P1 的性能基线：同一批场景在 `policy = .legacy`（修复前）与
// `.fixed`（修复后）下各跑一遍，对比请求次数与 token 估算 ——
// **模拟对比**，不是真实模型调用（真实模型的数字见交付报告里的"不可观测"说明）。

var failures = 0
func check(_ name: String, _ cond: Bool, _ extra: String = "") {
    if cond { print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ \(name) \(extra)") }
}
func checkEq<T: Equatable>(_ name: String, _ got: T, _ want: T) {
    if got == want { print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ \(name) 实际=\(got) 期望=\(want)") }
}

let endSignal = "[[FINAL_ANSWER]]"

// MARK: - 场景脚本

/// 一轮里模型产出的东西（够表达线上见过的所有收尾形态）。
enum Round {
    /// 提示词要求的形态：先输出暗号，再输出正文。
    /// `stopStreamAtEndSignal = true`（修复前）会在这里掐断流 —— 正文被整体丢掉。
    case signalThenBody(String)
    /// 有些模型反过来：正文在前、暗号在后。
    case bodyThenSignal(String)
    /// 只输出暗号（生成被截断 / 模型只学会了标记）。
    case signalOnly
    /// 纯正文：既没暗号也没工具调用。
    case plain(String)
    /// 空回复。
    case empty
    /// 有效工具调用（签名 = 工具名 + 参数 JSON）。
    case toolCall(String, String)
}

/// 一次 run 的可观测结果。
struct Trace {
    var requests = 0
    var answer: String?
    var reason: AgentTerminalReason?
    var toolRounds = 0
    var clearedCheckpoint = false
    var hitScriptEnd = false
    var estimatedInputTokens = 0

    var answered: Bool { !(answer ?? "").isEmpty }
}

/// 复刻 run() 的决策顺序：每轮一次模型请求 → 分类 → 结束或继续。
/// 脚本用尽后**重复最后一轮**（模拟模型在同样上下文下给出同样的东西）。
func simulate(_ rounds: [Round],
              policy: AgentLoopPolicy,
              useCloud: Bool = true,
              maxRequests: Int = 40) -> Trace {
    var trace = Trace()
    var terminator = AgentLoopTerminator(policy: policy)
    var index = 0
    // 模拟"每轮都要重发一遍历史"：这里只用一个粗略的上下文增长量估算 token 趋势。
    var historyChars = 1200

    while true {
        // 已经结束 → **绝不再请求模型**。这条断言是整个 P0 的地基。
        if terminator.isFinished { break }
        if trace.requests >= maxRequests { trace.hitScriptEnd = true; break }

        let round = rounds[min(index, rounds.count - 1)]
        index += 1
        trace.requests += 1
        historyChars += 400
        trace.estimatedInputTokens += max(1, Int(Double(historyChars) * 0.4))
        terminator.beginRound()

        switch round {
        case .toolCall(let name, let signature):
            let verdict = useCloud
                ? terminator.registerCallSet([signature])
                : terminator.registerCallSignature(signature)
            switch verdict {
            case .proceed, .warning:
                terminator.noteToolCall()
                trace.toolRounds += 1
                historyChars += 600        // 工具结果回填
                continue
            case .abort:
                let msg = "已停止：同一工具（\(name)）用同一组参数反复调用。以上是用当前结果能给出的回答。"
                terminator.finish(.repeatToolCalls, answer: msg)
                trace.answer = msg
                trace.reason = .repeatToolCalls
                trace.toolRounds += 1
            }

        case .signalThenBody(let body), .bodyThenSignal(let body):
            let raw: String
            if case .signalThenBody = round {
                // 修复前：流式在暗号处掐断 → 本轮捕获到的原始文本里**没有正文**。
                raw = policy.stopStreamAtEndSignal ? endSignal : endSignal + "\n\n" + body
            } else {
                // 正文在前：掐断与否都拿到了正文，两种策略都该正常收尾。
                raw = body + "\n\n" + endSignal
            }
            let extracted = AgentFinalAnswer.extract(from: raw, endSignal: endSignal)
            switch terminator.evaluateEndSignal(answer: extracted) {
            case .finalAnswer(let answer):
                trace.answer = answer
                trace.reason = .endSignal
            case .retryOnceForBody:
                historyChars += 200
                continue
            case .finishWithoutBody(let fallback):
                trace.answer = fallback
                trace.reason = .endSignalWithoutBody
            }

        case .signalOnly:
            let extracted = AgentFinalAnswer.extract(from: endSignal, endSignal: endSignal)
            switch terminator.evaluateEndSignal(answer: extracted) {
            case .finalAnswer(let answer):
                trace.answer = answer
                trace.reason = .endSignal
            case .retryOnceForBody:
                historyChars += 200
                continue
            case .finishWithoutBody(let fallback):
                trace.answer = fallback
                trace.reason = .endSignalWithoutBody
            }

        case .plain(let text):
            switch terminator.evaluatePlainRound(text) {
            case .keepThinking:
                historyChars += 200
                continue
            case .finishAsAnswer(let answer, let reason):
                trace.answer = answer
                trace.reason = reason
            }

        case .empty:
            switch terminator.evaluatePlainRound("") {
            case .keepThinking:
                continue
            case .finishAsAnswer(let answer, let reason):
                trace.answer = answer
                trace.reason = reason
            }
        }

        trace.clearedCheckpoint = terminator.clearsCheckpointOnFinish
        break
    }

    if trace.answer == nil { trace.answer = terminator.finalAnswer }
    if trace.reason == nil { trace.reason = terminator.terminalReason }
    trace.clearedCheckpoint = terminator.clearsCheckpointOnFinish
    return trace
}

// MARK: - 测试数据

/// 一段完整结论（≥ 24 字，用于相似度判定）。
let answer = "结论：LumenAI 用 XcodeGen 从 project.yml 生成 Xcode 工程，"
    + "构建命令是 xcodegen generate 加 xcodebuild -scheme LumenAI。"
/// 同一段结论的**改写版**：意思一样、措辞不同（修复前的"前缀/包含"判据认不出来）。
let answerReworded = "结论：LumenAI 是拿 XcodeGen 从 project.yml 生成 Xcode 工程的，"
    + "构建命令为 xcodegen generate，然后 xcodebuild -scheme LumenAI。"
/// 明显不同的结论（绝不能被判成"同一个答案"）。
let answerDifferent = "对不起，我不知道这个问题的答案，"
    + "需要你补充更多信息才能继续，比如具体想构建哪一个 target。"
/// 正常的中间思考（短、不构成结论）。
let intermediate = "我先看看 project.yml。"

print("== 1. 结束暗号解析（纯函数）==")
do {
    checkEq("暗号在前：正文被取出",
            AgentFinalAnswer.extract(from: endSignal + "\n" + answer, endSignal: endSignal) ?? "nil",
            answer)
    check("暗号在后：正文被取出",
          AgentFinalAnswer.extract(from: answer + "\n" + endSignal, endSignal: endSignal) == answer)
    check("只有暗号：返回 nil（由终止状态机兜底）",
          AgentFinalAnswer.extract(from: endSignal, endSignal: endSignal) == nil)
    check("没有暗号：返回 nil",
          AgentFinalAnswer.extract(from: answer, endSignal: endSignal) == nil)
    check("暗号不区分大小写",
          AgentFinalAnswer.contains("[[final_answer]]", endSignal: endSignal))
}

print("== 2. 相似度判定 ==")
do {
    check("完全相同 → 同一答案",
          AgentAnswerSimilarity.isSameAnswer(answer, answer, policy: .fixed))
    check("改写版 → 同一答案（修复前认不出来）",
          AgentAnswerSimilarity.isSameAnswer(answer, answerReworded, policy: .fixed))
    check("改写版在 legacy 判据下**不**算同一答案（复现旧行为）",
          !AgentAnswerSimilarity.isSameAnswer(answer, answerReworded, policy: .legacy))
    check("不同结论 → 不是同一答案",
          !AgentAnswerSimilarity.isSameAnswer(answer, answerDifferent, policy: .fixed))
    check("太短的段（中间思考）不参与判定",
          !AgentAnswerSimilarity.isSameAnswer(intermediate, intermediate, policy: .fixed))
}

print("== 3. 正常收尾：一轮就结束，不再请求 ==")
do {
    let t = simulate([.signalThenBody(answer)], policy: .fixed)
    checkEq("流式（暗号在前）请求次数 = 1", t.requests, 1)
    checkEq("流式（暗号在前）拿到完整正文", t.answer ?? "nil", answer)
    checkEq("终止原因 = endSignal", t.reason, .endSignal)
    check("结束态清掉断点存档（否则前台化会自己再跑一遍）", t.clearedCheckpoint)

    let t2 = simulate([.bodyThenSignal(answer)], policy: .fixed)
    checkEq("暗号在后：请求次数 = 1", t2.requests, 1)
    checkEq("暗号在后：正文完整", t2.answer ?? "nil", answer)
}

print("== 4. 复现修复前的两个 bug（legacy 策略下必现）==")
do {
    let legacy = simulate([.signalThenBody(answer)], policy: .legacy)
    check("修复前：暗号处掐断 → 正文丢失，循环停不下来（请求被顶到脚本上限）",
          legacy.hitScriptEnd && legacy.answer != answer, "requests=\(legacy.requests)")
    let fixed = simulate([.signalThenBody(answer)], policy: .fixed)
    check("修复后：同样脚本 1 次请求就结束", fixed.requests == 1 && fixed.answer == answer)

    // 断点存档：修复前"出了最终答案但不清档"→ ChatView 回前台自动续跑（用户看到的
    // 正是"答案都显示出来了，它还在继续请求模型"）。
    check("修复前：拿到最终答案后**不**清断点存档（这就是那个复活 bug）",
          !legacy.clearedCheckpoint)
    check("修复后：拿到最终答案即清档", fixed.clearedCheckpoint)
}

print("== 5. 模型不输出暗号、直接写出结论 ==")
do {
    let t = simulate([.plain(answer), .plain(answer)], policy: .fixed)
    checkEq("连续两轮同一结论 → 第 2 轮收尾", t.requests, 2)
    checkEq("返回最后一段正文", t.answer ?? "nil", answer)
    checkEq("终止原因 = plainTextAnswer", t.reason, .plainTextAnswer)
    check("清档", t.clearedCheckpoint)

    // 改写版（修复前认不出来）—— 修复前要烧到第 4 轮。
    let rewordedLegacy = simulate([.plain(answer), .plain(answerReworded), .plain(answer), .plain(answerReworded), .plain(answer)],
                                  policy: .legacy)
    let rewordedFixed = simulate([.plain(answer), .plain(answerReworded), .plain(answer), .plain(answerReworded), .plain(answer)],
                                 policy: .fixed)
    check("改写版：修复前 >2 次请求（多烧请求）", rewordedLegacy.requests > 2,
          "requests=\(rewordedLegacy.requests)")
    checkEq("改写版：修复后 2 次请求收尾", rewordedFixed.requests, 2)

    // 反向保护 + 有界收敛。
    // 保护：短中间思考**不会在前两轮**被当成结论（否则会砍掉还在推进的任务）。
    let cautiousEarly = simulate([.plain(intermediate)], policy: .fixed, maxRequests: 2)
    check("短中间思考：第 2 轮之前不会被当成结论（保护任务成功率）",
          cautiousEarly.answer == nil && cautiousEarly.hitScriptEnd)

    // 有界：又短又不带暗号的结论必须收敛。相似度要 ≥24 字、连续无动作要 ≥80 字，
    // 短结论两边都够不着 —— 没有硬上限就会重发到软上限 150 轮（校验复查发现的残留）。
    let bounded = simulate([.plain(intermediate)], policy: .fixed)
    checkEq("连续无动作到硬上限（3 轮）即收尾", bounded.requests, 3)
    checkEq("收尾用最后一段正文", bounded.answer ?? "nil", intermediate)
    checkEq("终止原因 = plainTextStreak", bounded.reason, .plainTextStreak)
    check("硬上限出口也清档（否则下次前台化会复活）", bounded.clearedCheckpoint)

    let boundedLegacy = simulate([.plain(intermediate)], policy: .legacy, maxRequests: 12)
    check("修复前：短正文结论会一路重发（顶到脚本上限）", boundedLegacy.hitScriptEnd,
          "requests=\(boundedLegacy.requests)")
}

print("== 6. 只有暗号 / 空回复：必须收敛，不能无限重试 ==")
do {
    let t = simulate([.signalOnly], policy: .fixed)
    checkEq("只有暗号：允许补一次正文 → 第 2 轮收尾", t.requests, 2)
    checkEq("终止原因 = endSignalWithoutBody", t.reason, .endSignalWithoutBody)
    check("兜底文案不为空（不能让用户什么都看不到）", t.answered)

    let empty = simulate([.empty], policy: .fixed)
    checkEq("连续空回复：2 轮后收尾", empty.requests, 2)
    checkEq("终止原因 = emptyOutput", empty.reason, .emptyOutput)

    let emptyLegacy = simulate([.empty], policy: .legacy, maxRequests: 12)
    check("修复前：空回复会一直请求到轮次上限", emptyLegacy.hitScriptEnd,
          "requests=\(emptyLegacy.requests)")
}

print("== 7. 工具调用不被误判成最终答案 ==")
do {
    let t = simulate([.toolCall("shell", "shell|{\"cmd\":\"ls\"}"),
                      .signalThenBody(answer)], policy: .fixed)
    checkEq("工具调用 + 收尾 = 2 次请求", t.requests, 2)
    checkEq("工具真的执行了 1 轮", t.toolRounds, 1)
    checkEq("最终答案来自工具之后的那一轮", t.answer ?? "nil", answer)

    // 云端一轮多调用：集合判定。A→B→A 这种来回调用不算空转。
    var repeatProbe = AgentLoopTerminator(policy: .fixed)
    checkEq("同一调用第 1 次：继续", repeatProbe.registerCallSet(["a|1"]), .proceed)
    checkEq("同一调用第 2 次：只提示、不中止", repeatProbe.registerCallSet(["a|1"]), .warning(round: 2))
    checkEq("同一批调用换顺序仍算同一批", repeatProbe.registerCallSet(["a|1"]), .abort)
    let t3 = simulate([.toolCall("a", "a|1")], policy: .fixed)
    checkEq("同一调用连续 3 次 → 第 3 轮中止", t3.requests, 3)
    checkEq("终止原因 = repeatToolCalls", t3.reason, .repeatToolCalls)
    check("中止也属于「任务结束」→ 清档", t3.clearedCheckpoint)
}

print("== 8. 完成事件的幂等性（重复收到完成事件不会重复完成）==")
do {
    var terminator = AgentLoopTerminator(policy: .fixed)
    _ = terminator.evaluateEndSignal(answer: answer)
    let firstReason = terminator.terminalReason
    let firstAnswer = terminator.finalAnswer
    _ = terminator.evaluateEndSignal(answer: answerReworded)
    terminator.finish(.softLimit, answer: "不应该覆盖")
    checkEq("终止原因不被第二次完成事件改写", terminator.terminalReason, firstReason)
    checkEq("返回正文不被改写", terminator.finalAnswer ?? "nil", firstAnswer ?? "nil")
    check("已结束状态可查（循环据此不再请求模型）", terminator.isFinished)
}

print("== 9. 取消 / 生成失败：保留断点存档，且不再发请求 ==")
do {
    var terminator = AgentLoopTerminator(policy: .fixed)
    terminator.beginRound()
    terminator.finish(.cancelled, answer: nil)
    check("取消 → 不清档（回前台要能续跑）", !terminator.clearsCheckpointOnFinish)

    // 生成失败：run() 直接 return，没有终止态 —— 同样不能清档。
    let never = AgentLoopTerminator(policy: .fixed)
    check("没有终止态 → 不清档（生成失败/打断时保留存档）", !never.clearsCheckpointOnFinish)

    // 取消之后即使脚本里还有内容，也不该再产生请求（模拟器在 isFinished 处直接 break）。
    var t = Trace()
    var term = AgentLoopTerminator(policy: .fixed)
    term.finish(.cancelled, answer: nil)
    for _ in 0..<5 {
        if term.isFinished { break }
        t.requests += 1
    }
    checkEq("取消后请求次数保持 0", t.requests, 0)
}

print("== 10. 性能对比（模拟：同一批场景 legacy vs fixed）==")
do {
    // 每个场景：脚本 + 说明。数字是**模拟的**请求次数与 token 估算，
    // 不是真实模型调用（真实模型的 token 只能由服务端返回，见交付说明）。
    let scenarios: [(String, [Round])] = [
        ("暗号在前（提示词要求的形态）", [.signalThenBody(answer)]),
        ("暗号在后", [.bodyThenSignal(answer)]),
        ("无暗号：连着两轮同一结论", [.plain(answer), .plain(answer)]),
        ("无暗号：改写版结论重复", [.plain(answer), .plain(answerReworded), .plain(answer), .plain(answerReworded), .plain(answer)]),
        ("无暗号：短结论（<80字，够不着任何旧判据）", [.plain(intermediate)]),
        ("只有暗号没有正文", [.signalOnly]),
        ("空回复", [.empty]),
        ("工具调用 → 收尾", [.toolCall("shell", "shell|{\"cmd\":\"ls\"}"), .signalThenBody(answer)]),
        ("同参数重复调用", [.toolCall("shell", "shell|{\"cmd\":\"ls\"}")]),
    ]

    var legacyRequests = 0, fixedRequests = 0
    var legacyTokens = 0, fixedTokens = 0
    var legacyAnswered = 0, fixedAnswered = 0
    /// 中英混排没法用 `%s` 对齐（`%s` 只吃 C 字符串），按字符宽度手动补空格。
    func pad(_ s: String, _ width: Int) -> String {
        let w = s.reduce(0) { $0 + ($1.unicodeScalars.first.map { $0.value > 0x2E80 ? 2 : 1 } ?? 1) }
        return s + String(repeating: " ", count: max(1, width - w))
    }
    print("  " + pad("场景", 34) + pad("旧请求", 10) + pad("新请求", 10)
          + pad("旧token", 12) + "新token")
    for (name, script) in scenarios {
        let l = simulate(script, policy: .legacy, maxRequests: 40)
        let f = simulate(script, policy: .fixed, maxRequests: 40)
        legacyRequests += l.requests; fixedRequests += f.requests
        legacyTokens += l.estimatedInputTokens; fixedTokens += f.estimatedInputTokens
        if l.answered { legacyAnswered += 1 }
        if f.answered { fixedAnswered += 1 }
        print("  " + pad(name, 34) + pad("\(l.requests)", 10) + pad("\(f.requests)", 10)
              + pad("\(l.estimatedInputTokens)", 12) + "\(f.estimatedInputTokens)")
    }
    print("  ── 合计 ──")
    print("  模型请求次数：旧 \(legacyRequests) → 新 \(fixedRequests)")
    print("  估算输入 token：旧 \(legacyTokens) → 新 \(fixedTokens)")
    print("  产出可用回答的场景数：旧 \(legacyAnswered)/\(scenarios.count) → 新 \(fixedAnswered)/\(scenarios.count)")

    check("修复后请求次数不增加", fixedRequests <= legacyRequests,
          "old=\(legacyRequests) new=\(fixedRequests)")
    check("修复后产出可用回答的场景不少于修复前", fixedAnswered >= legacyAnswered)
}

print("")
if failures == 0 { print("✅ agent_loop 全部通过") }
else { print("❌ agent_loop 失败 \(failures) 项") ; exit(1) }
