import Foundation

// 断点存档的"清档规则"回归测试（P0 根因）。
//
// 现象：用户已经看到最终回答，Agent 却"还在继续跑 / 又发起了模型请求"。
// 根因：`AgentService.run` 里"出了最终答案就 return"的几条出口**没有清断点存档**，
// 于是盘上留着一份"被打断的任务"，ChatView 在回前台（scenePhase == .active）
// 或冷启动（onAppear）时会把整段历史重新跑一遍 —— 看起来就是答案出了还在跑，
// 而且每次都把最长 120 条历史重发一遍。
//
// 这里验证的是规则本身，不是 UI：**只有"任务真的结束"的出口才允许清档**，
// 取消 / 生成失败必须保留（那两种才真的需要续跑）。

var failures = 0
func check(_ name: String, _ cond: Bool, _ extra: String = "") {
    if cond { print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ \(name) \(extra)") }
}

/// 与 `AgentService.run` 里的 defer 逐字一致的一行：
///   if terminator.clearsCheckpointOnFinish { AgentCheckpointStore.shared.clear() }
/// 生产代码与测试共用同一个判据（`clearsCheckpointOnFinish`），避免两套规则漂移。
@MainActor
func finishRun(_ terminator: AgentLoopTerminator, store: AgentCheckpointStore) {
    if terminator.clearsCheckpointOnFinish { store.clear() }
}

@MainActor
func makeStore() -> (AgentCheckpointStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lumen-checkpoint-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (AgentCheckpointStore(url: dir.appendingPathComponent("agent_run_checkpoint.json")), dir)
}

@MainActor
func sampleCheckpoint(resumeCount: Int = 0) -> AgentRunCheckpoint {
    AgentRunCheckpoint(
        conversationID: UUID(),
        bubbleID: UUID(),
        history: [
            ChatMessage(role: .user, content: "帮我把项目里的 TODO 列出来"),
            ChatMessage(role: .assistant, content: "{\"name\": \"shell\", \"arguments\": {\"cmd\": \"rg TODO\"}}"),
            ChatMessage(role: .tool, content: "src/a.swift:12: // TODO: 修这个"),
        ],
        iteration: 2,
        toolCalls: [ChatMessage.ToolCall(id: "1", name: "shell", arguments: "{\"cmd\":\"rg TODO\"}")],
        startedAt: Date(),
        reason: "App 在上一轮进行中被系统回收",
        resumeCount: resumeCount)
}

// 顶层代码不是 MainActor 上下文，而存档 store 是 @MainActor 隔离的 ——
// 用一个 assumeIsolated 块把三段测试包起来（测试本身是同步的，不涉及并发）。
MainActor.assumeIsolated {

print("== 1. 存档读写 ==")
do {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }
    check("初始不存在存档", !store.exists)
    store.save(sampleCheckpoint())
    check("写盘后可读回", store.exists)
    let loaded = store.load()
    check("续跑要用的字段都在（轮次 / 历史条数 / 工具调用）",
          loaded?.iteration == 2 && loaded?.history.count == 3 && loaded?.toolCalls.count == 1)
    store.clear()
    check("清档后文件消失（否则下次启动会去续一个已完成的任务）", !store.exists)
}

print("== 2. 只有「任务真的结束」才清档 ==")
do {
    let (store, dir) = makeStore()
    defer { try? FileManager.default.removeItem(at: dir) }

    // 2a. 正常最终答案
    store.save(sampleCheckpoint())
    var done = AgentLoopTerminator(policy: .fixed)
    _ = done.evaluateEndSignal(answer: "这是最终回答，包含足够长度的正文内容用于验证。")
    finishRun(done, store: store)
    check("拿到最终答案 → 清档（修复前不清：这就是「答案出了还在跑」的根因）", !store.exists)

    // 2b. 取消：必须留着，回来要能续
    store.save(sampleCheckpoint())
    var cancelled = AgentLoopTerminator(policy: .fixed)
    cancelled.finish(.cancelled, answer: nil)
    finishRun(cancelled, store: store)
    check("被取消 → 保留存档（回前台自动续跑）", store.exists)

    // 2c. 生成失败：run() 直接 return，没有任何终止态
    store.save(sampleCheckpoint())
    let failed = AgentLoopTerminator(policy: .fixed)
    finishRun(failed, store: store)
    check("生成失败（无终止态）→ 保留存档", store.exists)

    // 2d. 空转中止 / 软上限：都属于"任务结束"
    for reason in [AgentTerminalReason.repeatToolCalls, .softLimit, .plainTextAnswer,
                   .plainTextStreak, .emptyOutput, .endSignalWithoutBody] {
        store.save(sampleCheckpoint())
        var t = AgentLoopTerminator(policy: .fixed)
        t.finish(reason, answer: "x")
        finishRun(t, store: store)
        check("\(reason.label) → 清档", !store.exists)
    }
}

print("== 3. 自动续跑的次数上限 ==")
do {
    check("续跑 0 次可以续", sampleCheckpoint(resumeCount: 0).canAutoResume)
    check("续跑 2 次可以续", sampleCheckpoint(resumeCount: 2).canAutoResume)
    check("续跑 3 次到上限（不再无限续）", !sampleCheckpoint(resumeCount: 3).canAutoResume)
}

}   // MainActor.assumeIsolated

print("")
if failures == 0 { print("✅ agent_checkpoint 全部通过") }
else { print("❌ agent_checkpoint 失败 \(failures) 项"); exit(1) }
