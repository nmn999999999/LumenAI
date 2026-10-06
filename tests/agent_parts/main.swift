import Foundation

// agentParts（ChatMessage.splitAgentParts）的单元验证。
//
// 这是「思考块 / 工具 chip / 正文 按真实输出顺序穿插渲染」的地基：
// 切分规则必须与运行时语义一致（工具 JSON 在 think 块之外才会被执行），
// chip 对齐必须用「名字 + 顺序」而不是纯序号（否则未知工具/去重会让后续全部错位一格）。

var failures = 0
func check(_ name: String, _ cond: Bool, _ extra: String = "") {
    if cond { print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ \(name) \(extra)") }
}

func call(_ name: String) -> ChatMessage.ToolCall {
    ChatMessage.ToolCall(id: UUID().uuidString, name: name, arguments: "{}")
}

/// 简写：把 parts 压成可读的形式做断言。
func shape(_ parts: [ChatMessage.AgentPart]) -> String {
    parts.map { p -> String in
        switch p {
        case .think(_, let closed): return closed ? "T" : "T?"
        case .toolCall(let i): return "C\(i)"
        case .text(let t): return "X(\(t.prefix(12)))"
        }
    }.joined(separator: " ")
}

func thinkIndex(_ parts: [ChatMessage.AgentPart]) -> Int? {
    parts.firstIndex { if case .think = $0 { return true }; return false }
}

// ── 1. 纯正文（无 think、无工具）────────────────────────────────
do {
    let m = ChatMessage(role: .assistant, content: "这是最终回答。")
    let p = m.agentParts
    check("纯正文 → 1 个 text", p.count == 1, shape(p))
    if case .text(let t) = p[0] { check("纯正文内容保留", t == "这是最终回答。") }
    else { check("纯正文内容保留", false) }
}

// ── 2. 单个 think + 正文（普通聊天的推理模型）────────────────────
do {
    let m = ChatMessage(role: .assistant, content: "<think>让我想想。</think>\n\n我想清楚了。")
    let p = m.agentParts
    check("单 think → T + X", p.count == 2, shape(p))
    if case .think(let t, let closed)? = p.first {
        check("think 内容与闭合状态", t == "让我想想。" && closed, t)
    } else { check("think 段存在", false, shape(p)) }
    check("think 在正文之前", thinkIndex(p) == 0, shape(p))
}

// ── 3. 多轮：think → 工具 JSON → think → 工具 JSON → think → 正文 ──
// 这是最核心的一条：改造前 parseThinkBlock 会把 3 段 think 合成一坨、
// 正文合成另一坨、chip 全堆顶部；现在必须交替。
do {
    let content = """
    <think>先搜一下。</think> {"name": "web_search", "arguments": {"query": "swift"}}
    <think>拿到结果了，再算一下。</think> {"name": "calculator", "arguments": {"expr": "1+1"}}
    <think>都齐了。</think>
    三步都完成了。
    """
    let m = ChatMessage(role: .assistant, content: content,
                        toolCalls: [call("web_search"), call("calculator")])
    let p = m.agentParts
    check("多轮 → T C0 T C1 T X 六段", p.count == 6, shape(p))
    check("末段是正文", {
        if case .text = p.last! { return true }
        return false
    }(), shape(p))
    let calls = p.compactMap { if case .toolCall(let i) = $0 { return i } else { return nil } }
    check("两个 chip 都出现", calls.count == 2, shape(p))
    check("chip 按出现顺序对齐 (0,1)", calls == [0, 1], shape(p))

    // 交替性：每个 chip 之前必须已经出现过至少一个非空段，且 chip 之后若有内容则继续交替
    // 更强的断言：第 1 个 chip 出现前不能已有第 2 个 chip，且第 1 个 chip 的位置在第 2 个之前
    if calls.count == 2 {
        check("chip 顺序 = 调用顺序", calls[0] < calls[1], shape(p))
    }
    // 每个 chip 前后都有段（思考驱动它、正文接住结果）
    if let c0 = p.firstIndex(where: { if case .toolCall = $0 { return true }; return false }) {
        check("第 1 个 chip 前有内容", c0 > 0, shape(p))
    }
}

// ── 4. 工具 JSON 落在 think 块**内部** → 当作思考，不产生 chip ────
// 与运行时一致：AgentService 先 stripThinkTags 再解析，块内 JSON 不会被执行。
do {
    let content = "<think>我在想 {\"name\": \"note\", \"arguments\": {}} 这样写对不对。</think>"
    let m = ChatMessage(role: .assistant, content: content, toolCalls: [call("note")])
    let p = m.agentParts
    // JSON 在 think 块内 → 不会被运行时执行 → 不能在原位置插入 chip（那等于谎报"调用了"）
    let chipsBeforeEnd = p.dropLast().contains { if case .toolCall = $0 { return true }; return false }
    check("think 内的 JSON 不在原位触发 chip", !chipsBeforeEnd, shape(p))
    // think 段必须把 JSON 当思考文本保留（否则内容凭空消失）
    let thinkHasJSON = p.contains { if case .think(let t, _) = $0 { return t.contains("\"name\"") }; return false }
    check("JSON 留在思考文本里", thinkHasJSON, shape(p))
    // chip 仍要补到末尾，一个都不能丢
    let lastIsChip: Bool = {
        guard let last = p.last else { return false }
        if case .toolCall = last { return true }
        return false
    }()
    check("未被 JSON 用上的 chip 补在末尾", lastIsChip, shape(p))
}

// ── 5. 未知工具的 JSON（toolCalls 里没有）→ 不产生 chip，也不吃掉后面的 chip ──
// 这是「按名字对齐」相对「按序号对齐」的关键差异：按序号会把后续 chip 全错位一格。
do {
    let content = """
    试试。{"name": "not_a_tool", "arguments": {}}
    换这个。{"name": "note", "arguments": {"text": "hi"}}
    """
    let m = ChatMessage(role: .assistant, content: content, toolCalls: [call("note")])
    let p = m.agentParts
    let calls = p.compactMap { if case .toolCall(let i) = $0 { return i } else { return nil } }
    check("未知工具 JSON 不产生 chip", calls.count == 1, shape(p))
    check("真实 chip 仍对齐到 index 0", calls == [0], shape(p))
}

// ── 6. 同名多次调用 → 按顺序各取一个，不会两个都指向同一个 ─────────
do {
    let content = """
    {"name": "http_get", "arguments": {"url": "https://a"}}
    {"name": "http_get", "arguments": {"url": "https://b"}}
    """
    let m = ChatMessage(role: .assistant, content: content,
                        toolCalls: [call("http_get"), call("http_get")])
    let p = m.agentParts
    let calls = p.compactMap { if case .toolCall(let i) = $0 { return i } else { return nil } }
    check("同名两次调用 → 两个不同 chip", calls == [0, 1], shape(p))
}

// ── 7. 未闭合 think（流式中）→ closed=false ─────────────────────
do {
    let m = ChatMessage(role: .assistant, content: "思考中但还没结束", isStreaming: true)
    let p = m.agentParts
    let hasOpenThink = p.contains { if case .think(_, false) = $0 { return true }; return false }
    check("无 think 标签 → 不产生 think 段", !hasOpenThink, shape(p))
}

do {
    let m = ChatMessage(role: .assistant, content: "我想想……还没完")
    // 无标签时整段是正文（改造前的 thinkContent 也是 nil，行为一致）
    let p = m.agentParts
    check("无标签 → 单个 text", p.count == 1, shape(p))
}

// ── 8. 未闭合工具 JSON（流式中只吐了一半）→ 当正文，不崩 ────────────
do {
    let m = ChatMessage(role: .assistant, content: "正在调用 {\"name\": \"note\", \"argu")
    let p = m.agentParts
    check("半截 JSON 不产生 chip", !p.contains { if case .toolCall = $0 { return true }; return false },
          shape(p))
    check("半截 JSON 不会让分段为空", !p.isEmpty, shape(p))
}

// ── 9. 空 content + 有 chip（旧档/极端情况）→ chip 全保留 ───────────
do {
    let m = ChatMessage(role: .assistant, content: "", toolCalls: [call("note"), call("shell")])
    let p = m.agentParts
    let calls = p.compactMap { if case .toolCall(let i) = $0 { return i } else { return nil } }
    check("空 content → 两个 chip 都在", calls == [0, 1], shape(p))
}

// ── 10. 代码围栏里的 JSON：与运行时一致，**会产生** chip ────────────
// 运行时 `parseToolOutcome` 先把 ```json / ``` 剥掉再解 JSON，所以围栏内的调用
// 确实会被执行 —— 渲染必须跟上（不显示 chip 等于"做了却没让用户看到"）。
do {
    let content = "```{\"name\": \"note\"}```\n\n回答"
    let m = ChatMessage(role: .assistant, content: content, toolCalls: [call("note")])
    let p = m.agentParts
    let calls = p.compactMap { if case .toolCall(let i) = $0 { return i } else { return nil } }
    check("代码围栏里的 JSON 产生 chip", calls == [0], shape(p))
}

// ── 11. 真实 agent 收尾形态：末尾是 [[FINAL_ANSWER]] + 正文 ─────────
do {
    let content = """
    先取数。{"name": "http_get", "arguments": {"url": "https://x"}}
    [[FINAL_ANSWER]]
    结论是 42。
    """
    let m = ChatMessage(role: .assistant, content: content, toolCalls: [call("http_get")])
    let p = m.agentParts
    let calls = p.compactMap { if case .toolCall(let i) = $0 { return i } else { return nil } }
    check("收尾：chip 对齐", calls == [0], shape(p))
    let lastText = p.reversed().first { if case .text = $0 { return true }; return false }
    if case .text(let t)? = lastText {
        check("收尾：正文含最终答案", t.contains("42"), shape(p))
        check("收尾：暗号仍在原始 content 中（渲染侧清理）",
              m.content.contains("[[FINAL_ANSWER]]"))
    } else {
        check("收尾：正文含最终答案", false, shape(p))
    }
}

// ── 12. 回归：visibleContent / thinkContent 不受影响 ────────────────
do {
    let m = ChatMessage(role: .assistant, content: "<think>这是思考。</think>这是回答。")
    check("visibleContent 剔除 think", m.visibleContent == "这是回答。",
          m.visibleContent)
    check("thinkContent 取出 think", m.thinkContent == "这是思考。",
          m.thinkContent ?? "nil")
}

print(failures == 0 ? "\n✅ agentParts 全部通过" : "\n❌ 失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)
