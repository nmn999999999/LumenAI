import Foundation

// Benchmark 成功判定契约的单元验证（纯函数，无 App 依赖，可单独 swiftc 编译）。
//
// 编译并运行：
//   swiftc -o /tmp/bv_tests \
//       LumenAI/Services/AgentPerf/BenchmarkVerdict.swift \
//       Tests/benchmark_verdict_tests.swift && /tmp/bv_tests
//
// 覆盖：场景契约的 8 个核心 case（要求/禁止/至少一次/环境不适用）+
//       轨迹指标（重复调用、覆盖率、无效调用）。
// 这些断言是**判定语义的回归防线**：以后谁把 required 改成「命中其一」，
// 这里会直接红。

var failures = 0
func check(_ name: String, _ cond: Bool, _ extra: String = "") {
    if cond { print("  ✓ \(name)") }
    else { failures += 1; print("  ✗ \(name) \(extra)") }
}

func verdict(_ contract: BenchmarkContract,
             called: [String],
             answer: String = "ok",
             external: [String] = []) -> BenchmarkVerdict {
    BenchmarkVerdict.evaluate(contract: contract, called: called,
                              answer: answer, externalTools: Set(external))
}

print("== 1. requiredTools 基本语义 ==")

// case 1: required=[A], actual=[A] => success
do {
    let c = BenchmarkContract(requiredTools: ["A"], answerCheck: .nonEmpty)
    let v = verdict(c, called: ["A"])
    check("case1 required=[A] actual=[A] → success", v.passed, v.failureSummary)
}

// case 2: required=[A,B], actual=[A] => FAIL（老逻辑在这里会判成功）
do {
    let c = BenchmarkContract(requiredTools: ["A", "B"], answerCheck: .nonEmpty)
    let v = verdict(c, called: ["A"])
    check("case2 required=[A,B] actual=[A] → FAIL", !v.passed)
    check("case2 失败原因点名缺失工具 B", v.failureSummary.contains("B"), v.failureSummary)
}

// case 3: required=[A,B], actual=[A,B] => PASS
do {
    let c = BenchmarkContract(requiredTools: ["A", "B"], answerCheck: .nonEmpty)
    check("case3 required=[A,B] actual=[A,B] → PASS", verdict(c, called: ["A", "B"]).passed)
}

// case 4: required=[], requiresTool=false, actual=[] => 成功与否只看答案校验
do {
    let ok = BenchmarkContract(answerCheck: .nonEmpty)
    let bad = BenchmarkContract(answerCheck: .contains("必须出现"))
    check("case4 无工具要求 + 答案非空 → success",
          verdict(ok, called: []).passed)
    check("case4 无工具要求 + 答案不含结果 → FAIL",
          !verdict(bad, called: []).passed)
}

// case 5: requiresTool=true, actual=[] => FAIL
do {
    let c = BenchmarkContract(requiresTool: true, answerCheck: .nonEmpty)
    let v = verdict(c, called: [])
    check("case5 requiresTool actual=[] → FAIL", !v.passed)
    check("case5 失败原因说明要一次调用", v.failureSummary.contains("0 次"), v.failureSummary)
}

// case 6: requiresTool=true + 外部宇宙非空, actual=[任意外部工具] => tool PASS
do {
    let c = BenchmarkContract(requiresTool: true, requiresExternalTool: true,
                              answerCheck: .nonEmpty)
    check("case6 调了外部工具 → tool PASS",
          verdict(c, called: ["mcp_weather"], external: ["mcp_weather", "mcp_time"]).toolPassed)
    let v = verdict(c, called: ["calculator"], external: ["mcp_weather"])
    check("case6 只调内置工具 → FAIL", !v.passed, v.failureSummary)
}

// case 7: forbiddenTools=[A], actual=[A] => FAIL
do {
    let c = BenchmarkContract(forbiddenTools: ["A"], answerCheck: .nonEmpty)
    check("case7 调了禁止工具 → FAIL", !verdict(c, called: ["A"]).passed)
    check("case7 没调禁止工具 → PASS", verdict(c, called: ["B"]).passed)
}

// case 8: required=[A], actual=[A,A,A] → 判定与只调一次完全一致（重复不加分）
do {
    let c = BenchmarkContract(requiredTools: ["A"], answerCheck: .nonEmpty)
    let once = verdict(c, called: ["A"])
    let triple = verdict(c, called: ["A", "A", "A"])
    check("case8 重复调用不改变成功判定",
          once.passed && triple.passed && once == triple,
          "once=\(once.passed) triple=\(triple.passed)")
    let records = [BenchmarkToolCallRecord(name: "A", arguments: "{}"),
                   BenchmarkToolCallRecord(name: "A", arguments: "{}"),
                   BenchmarkToolCallRecord(name: "A", arguments: "{}")]
    let t = BenchmarkTrajectory.compute(called: ["A", "A", "A"], records: records, contract: c)
    check("case8 重复次数 = 2", t.duplicateCallCount == 2, "\(t.duplicateCallCount)")
    check("case8 覆盖率仍是 1.0", t.requiredCoverage == 1.0, "\(t.requiredCoverage ?? -1)")
    check("case8 调用次数如实记 3", t.toolCallCount == 3, "\(t.toolCallCount)")
}

print("== 2. 环境不适用 / 答案维度 ==")

// case 9: mcp 场景要求外部工具但环境一个都没装 → notApplicable（不计入成功率）
do {
    let c = BenchmarkContract(requiresTool: true, requiresExternalTool: true,
                              answerCheck: .nonEmpty)
    let v = verdict(c, called: [], external: [])
    check("case9 外部宇宙为空 → notApplicable", v.isNotApplicable, v.failureSummary)
    check("case9 notApplicable 不算 passed", !v.passed)
}

// case 10: 工具全对但答案不含结果 → FAIL（判定必须两个维度都过）
do {
    let c = BenchmarkContract(requiredTools: ["calculator"], answerCheck: .contains("1024"))
    check("case10 工具对 + 答案对 → PASS",
          verdict(c, called: ["calculator"], answer: "结果是 1024").passed)
    let v = verdict(c, called: ["calculator"], answer: "我算过了，是 999")
    check("case10 工具对 + 答案错 → FAIL", !v.passed, v.failureSummary)
}

// case 11: coverage = 已调 / 必须
do {
    let c = BenchmarkContract(requiredTools: ["A", "B", "C"])
    let t = BenchmarkTrajectory.compute(called: ["A", "B"],
                                        records: [BenchmarkToolCallRecord(name: "A", arguments: ""),
                                                  BenchmarkToolCallRecord(name: "B", arguments: "")],
                                        contract: c)
    check("case11 coverage 2/3 ≈ 0.667", abs((t.requiredCoverage ?? 0) - 0.6667) < 0.001,
          "\(t.requiredCoverage ?? -1)")
    check("case11 无 requiredTools 时 coverage 为 nil",
          BenchmarkTrajectory.compute(called: [], records: [], contract: BenchmarkContract())
            .requiredCoverage == nil)
}

// case 12: 同一目的多条等价路径（requiresAllRequiredTools=false）→ 命中其一即可
do {
    let c = BenchmarkContract(requiredTools: ["file_op", "shell"],
                              requiresAllRequiredTools: false, answerCheck: .nonEmpty)
    check("case12 any-of 命中 shell → PASS", verdict(c, called: ["shell"]).passed)
    check("case12 any-of 一个都没中 → FAIL", !verdict(c, called: ["calculator"]).passed)
}

// case 13: forbidden 优先于 required —— 都满足了仍然失败
do {
    let c = BenchmarkContract(requiredTools: ["A"], forbiddenTools: ["B"],
                              answerCheck: .nonEmpty)
    let v = verdict(c, called: ["A", "B"])
    check("case13 required 满足但 forbidden 被调 → FAIL", !v.passed, v.failureSummary)
}

// case 14: 轨迹里的无效/失败调用统计
do {
    let c = BenchmarkContract(requiredTools: ["A"])
    let records = [
        BenchmarkToolCallRecord(name: "A", arguments: "{}"),
        BenchmarkToolCallRecord(name: "A", arguments: "{}", isError: true, errorCode: "timeout"),
        BenchmarkToolCallRecord(name: "ghost", arguments: "{}", isError: true, errorCode: "not_found"),
    ]
    let t = BenchmarkTrajectory.compute(called: ["A", "A", "ghost"], records: records, contract: c)
    check("case14 无效调用(not_found) = 1", t.invalidCallCount == 1, "\(t.invalidCallCount)")
    check("case14 失败调用(error) = 2", t.errorCallCount == 2, "\(t.errorCallCount)")
    check("case14 去重后重复 = 1", t.duplicateCallCount == 1, "\(t.duplicateCallCount)")
    check("case14 不同工具数 = 2", t.uniqueToolCount == 2, "\(t.uniqueToolCount)")
}

// case 15: 答案校验器自身的组合语义
do {
    check("case15 containsAll 全中", BenchmarkAnswerCheck.containsAll(["a", "b"]).evaluate("AB cd"))
    check("case15 containsAll 缺一 → false", !BenchmarkAnswerCheck.containsAll(["a", "z"]).evaluate("AB cd"))
    check("case15 containsAny 命中其一", BenchmarkAnswerCheck.containsAny(["z", "cd"]).evaluate("AB cd"))
    check("case15 regex 命中", BenchmarkAnswerCheck.regex("[0-9a-f]{8}-[0-9a-f]{4}").evaluate("id: 1234ABCD-5678-x"))
    check("case15 非法正则判 false 不崩", !BenchmarkAnswerCheck.regex("(").evaluate("anything"))
    check("case15 all 组合", BenchmarkAnswerCheck.all([.nonEmpty, .contains("99")]).evaluate("答案 99"))
    check("case15 空答案 → nonEmpty false", !BenchmarkAnswerCheck.nonEmpty.evaluate("   "))
}

print()
if failures == 0 { print("✅ 全部 benchmark 判定测试通过") }
else { print("❌ \(failures) 项失败") }
exit(failures == 0 ? 0 : 1)
