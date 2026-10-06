import Foundation

// MARK: - Benchmark 成功判定契约
//
// 为什么独立成文件（只依赖 Foundation，不碰 App 类型）：
//   1. 判定必须是**纯函数** —— baseline 与 optimized 走同一份代码、同一份规则，
//      才谈得上"性能优化没有以降低任务成功率为代价"。判定散在 sample 的计算属性里时，
//      没法单独验证它的语义（原来连测试都写不了）。
//   2. 独立 + 无 App 依赖意味着可以被 `swiftc` 单独编译出来跑断言
//      （见 `Tests/benchmark_verdict_tests.swift`），不需要起模拟器。
//
// 刻意**不**放进这里的东西：工具选择策略、路由、压缩、prompt —— 那些是被测对象。
// 这里只有"这次跑成没跑成"的定义。

// MARK: - 最终答案校验

/// 场景对最终答案的要求。**不只判断非空**：工具调用只是"走了哪条路"的证据，
/// 答案里的结果才是"任务做完没做完"的证据。
enum BenchmarkAnswerCheck: Sendable, Equatable {
    /// 非空即可（没有唯一预期结果的场景，例如开放问答）。
    case nonEmpty
    /// 答案包含该子串（大小写不敏感）。
    case contains(String)
    /// 包含全部子串。
    case containsAll([String])
    /// 包含任一子串（多个可接受的等价说法）。
    case containsAny([String])
    /// 正则命中（大小写不敏感；模式不合法时判 false，不抛异常）。
    case regex(String)
    /// 全部子检查通过才算通过。
    case all([BenchmarkAnswerCheck])

    func evaluate(_ answer: String) -> Bool {
        switch self {
        case .nonEmpty:
            return !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .contains(let s):
            return answer.range(of: s, options: .caseInsensitive) != nil
        case .containsAll(let list):
            return list.allSatisfy { answer.range(of: $0, options: .caseInsensitive) != nil }
        case .containsAny(let list):
            return list.contains { answer.range(of: $0, options: .caseInsensitive) != nil }
        case .regex(let pattern):
            return answer.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        case .all(let list):
            return list.allSatisfy { $0.evaluate(answer) }
        }
    }

    var describe: String {
        switch self {
        case .nonEmpty: return "非空"
        case .contains(let s): return "包含「\(s)」"
        case .containsAll(let l): return "包含全部 \(l.joined(separator: " / "))"
        case .containsAny(let l): return "包含其一 \(l.joined(separator: " | "))"
        case .regex(let p): return "匹配 /\(p)/"
        case .all(let l): return l.map(\.describe).joined(separator: " 且 ")
        }
    }
}

// MARK: - 场景契约

/// 一个场景"跑成什么样才算成功"的完整定义。
///
/// 之所以不再用一个 `expectedAnyTools` 打天下：那一个字段同时承担了
/// 「必须全调用」「调一个就行」「不许调工具」「没指定但得调一个」四种互斥语义，
/// 结果 `[]` 既可以读成"预期不调用工具"，也可以读成"随便调什么"。
/// 这四种语义现在各自有名字，谁也不能再互相冒充。
struct BenchmarkContract: Sendable, Equatable {
    /// 必须被调用的工具集合（名字以 run 时的工具目录为准）。
    var requiredTools: [String] = []
    /// `true`：`requiredTools` **全部**都要调用过（多工具任务用这个）。
    /// `false`：`requiredTools` 里**至少一个**被调用过即可（同一目的有多条等价路径时用，例如
    /// 「列目录」既可以用 `file_op` 也可以用 `shell`）。
    var requiresAllRequiredTools: Bool = true
    /// 允许出现、但不强制的工具（只用于记录，不参与成败判定）。
    var optionalTools: [String] = []
    /// 调了就判失败的工具（安全/越界类场景用）。
    var forbiddenTools: [String] = []
    /// `true`：本场景要求至少发生一次合法 tool call，但**不限定**是哪个工具。
    var requiresTool: Bool = false
    /// `true`：在 `requiresTool` 基础上，还要求其中至少一个调用来自**外部宇宙**
    /// （MCP / 插件工具，由调用方把实际已安装的名字传给判定）。
    /// 这是 `mcp_tool` 场景的正确表达：它要的是"用你当前真有的外部工具"，
    /// 而不是"别调工具"，也不是"必须叫某一个写死的插件名"。
    var requiresExternalTool: Bool = false
    /// 最终答案的校验。`nil` = 不要求给出答案（目前默认场景都要求）。
    var answerCheck: BenchmarkAnswerCheck?

    /// 本契约是否声明了任何工具要求（决定 trajectory 里 coverage 有没有意义）。
    var hasToolRequirement: Bool {
        !requiredTools.isEmpty || requiresTool || !forbiddenTools.isEmpty
    }
}

// MARK: - 工具要求的判定结果

/// 工具侧的判定结果。**三态**而不是两态：
/// `.notApplicable` 是为了诚实地表达"环境不满足，这次跑没法用来评价 agent"——
/// 例如 `mcp_tool` 要求外部工具、而用户一台 MCP 服务器/插件都没装。
/// 这种样本既不该算成功（没有证据表明任务被完成），也不该算失败（不是 agent 的锅），
/// 更不该被两变体算成同一个失败去稀释对比（见 aggregate 的 `notApplicableCount`）。
enum BenchmarkToolOutcome: Sendable, Equatable {
    case satisfied
    case notApplicable(String)
    case failed(String)

    var isSatisfied: Bool {
        if case .satisfied = self { return true }
        return false
    }
    var isNotApplicable: Bool {
        if case .notApplicable = self { return true }
        return false
    }
    var reason: String {
        switch self {
        case .satisfied: return "满足"
        case .notApplicable(let r), .failed(let r): return r
        }
    }
}

/// 一次场景执行的判定结论。
struct BenchmarkVerdict: Sendable, Equatable {
    let toolOutcome: BenchmarkToolOutcome
    let answerPassed: Bool
    let answerDetail: String

    /// 工具要求达成（`.notApplicable` 不算达成，也不算失败，见上）。
    var toolPassed: Bool { toolOutcome.isSatisfied }
    /// 环境不适用（aggregate 会把它从成功率分母里剔除，并单独计数报告）。
    var isNotApplicable: Bool { toolOutcome.isNotApplicable }
    /// 任务成功 = 工具侧达成 **且** 答案通过。两道关都由同一份代码判定。
    /// 刻意**不**做"工具对了就放行答案"或反之 —— 那正是要修的漏洞。
    var passed: Bool { toolPassed && answerPassed }

    /// 失败原因（成功时为空串），用于 UI 与报告，便于事后判断"是没调对工具还是答案没落地"。
    var failureSummary: String {
        var reasons: [String] = []
        if case .failed(let r) = toolOutcome { reasons.append("工具: \(r)") }
        if !answerPassed { reasons.append("答案: \(answerDetail)") }
        return reasons.joined(separator: "；")
    }

    /// 判定入口（纯函数）。
    /// - Parameters:
    ///   - called: 本次 run 实际发起的工具名，**按顺序**（含失败/被拒的调用 —— 试过也算试过）。
    ///   - externalTools: 当前实际可用的外部工具名（MCP + 插件）。`requiresExternalTool`
    ///     为空集时判定为 `.notApplicable`，而不是把"环境里根本没有"算成 agent 失败。
    static func evaluate(contract: BenchmarkContract,
                         called: [String],
                         answer: String,
                         externalTools: Set<String> = []) -> BenchmarkVerdict {
        let toolOutcome = evaluateTools(contract: contract, called: called, externalTools: externalTools)

        let answerPassed: Bool
        let answerDetail: String
        if let check = contract.answerCheck {
            answerPassed = check.evaluate(answer)
            answerDetail = answerPassed ? "满足" : "不满足（要求: \(check.describe)）"
        } else {
            answerPassed = true
            answerDetail = "本场景不要求最终答案"
        }
        return BenchmarkVerdict(toolOutcome: toolOutcome, answerPassed: answerPassed, answerDetail: answerDetail)
    }

    /// 工具侧判定。顺序：禁止 → 必须 → 至少一次调用。前一条失败就不再看后面（原因唯一，好排查）。
    static func evaluateTools(contract: BenchmarkContract,
                              called: [String],
                              externalTools: Set<String>) -> BenchmarkToolOutcome {
        // 1) forbidden 优先：调了禁用工具，后面的覆盖率再高也不能算过。
        if !contract.forbiddenTools.isEmpty {
            let calledSet = Set(called)
            let hit = contract.forbiddenTools.filter { calledSet.contains($0) }
            if !hit.isEmpty {
                return .failed("调用了禁止的工具 \(hit.joined(separator: ", "))")
            }
        }

        // 2) requiredTools
        if !contract.requiredTools.isEmpty {
            let calledSet = Set(called)
            let missing = contract.requiredTools.filter { !calledSet.contains($0) }
            if contract.requiresAllRequiredTools {
                if !missing.isEmpty {
                    return .failed("缺少必需工具 \(missing.joined(separator: ", "))"
                                   + "（已调: \(called.isEmpty ? "无" : called.joined(separator: ", "))）")
                }
            } else if missing.count == contract.requiredTools.count {
                return .failed("requiredTools 中没有任何一个被调用（候选: "
                               + "\(contract.requiredTools.joined(separator: ", "))）")
            }
            return .satisfied
        }

        // 3) requiresTool（不限定具体工具名）
        if contract.requiresTool {
            // 先看环境再看行为：外部宇宙为空时，模型"没调"还是"调了别的"都不重要 ——
            // 这一轮根本没有可评价的题目，判 notApplicable 而不是把环境缺失算成 agent 失败。
            if contract.requiresExternalTool, externalTools.isEmpty {
                return .notApplicable("环境未安装任何外部（MCP/插件）工具，本场景无法评价")
            }
            if called.isEmpty {
                return .failed("要求至少一次工具调用，实际 0 次")
            }
            if contract.requiresExternalTool, Set(called).isDisjoint(with: externalTools) {
                return .failed("要求调用外部工具之一（"
                               + "\(externalTools.sorted().joined(separator: ", "))），"
                               + "实际只调了 \(called.joined(separator: ", "))")
            }
            return .satisfied
        }

        // 4) 没有任何工具要求（纯问答）。
        return .satisfied
    }
}

// MARK: - Trajectory（轨迹）指标

/// 单次 run 的工具轨迹统计。判定关心"成没成"，这些关心"怎么成的 / 多浪费"。
/// baseline 与 optimized 用同一份计算逻辑（纯函数，无状态）。
struct BenchmarkTrajectory: Sendable, Equatable {
    /// 实际工具调用次数（含失败与被拒的尝试）。
    var toolCallCount: Int = 0
    /// 不同工具名个数。
    var uniqueToolCount: Int = 0
    /// 完全相同的（工具名 + 参数）重复调用次数，超出首次的都算。
    var duplicateCallCount: Int = 0
    /// 无效调用数：Agent 自己报「工具不存在」（`errorCode == "not_found"`）的调用。
    /// 用机器可读的错误码而不是"名字不在目录里"，是为了避免把**本轮新装的插件工具**
    /// 误判成无效 —— 目录是 run 开始时的快照，装完插件后调用它是合法的。
    var invalidCallCount: Int = 0
    /// 执行失败的调用数（`status == .error`，含超时/越界/参数错等一切失败）。
    var errorCallCount: Int = 0
    /// `requiredTools` 覆盖率 0...1；场景没有 requiredTools 时为 nil。
    var requiredCoverage: Double?

    static func compute(called: [String],
                        records: [BenchmarkToolCallRecord],
                        contract: BenchmarkContract) -> BenchmarkTrajectory {
        var t = BenchmarkTrajectory()
        t.toolCallCount = records.count
        t.uniqueToolCount = Set(records.map(\.name)).count

        // 重复：按「名字 + 参数原文」签名计数，多出来的次数即重复调用。
        var seen: Set<String> = []
        var duplicates = 0
        for r in records {
            let signature = r.name + "\u{0}" + r.arguments
            if seen.contains(signature) { duplicates += 1 } else { seen.insert(signature) }
        }
        t.duplicateCallCount = duplicates

        t.invalidCallCount = records.filter { $0.errorCode == "not_found" }.count
        t.errorCallCount = records.filter { $0.isError }.count

        if contract.requiredTools.isEmpty {
            t.requiredCoverage = nil
        } else {
            let calledSet = Set(called)
            let hit = contract.requiredTools.filter { calledSet.contains($0) }.count
            t.requiredCoverage = Double(hit) / Double(contract.requiredTools.count)
        }
        return t
    }
}

/// 判定/轨迹需要的最小调用记录（不依赖 `ChatMessage`，方便单独编译测试）。
struct BenchmarkToolCallRecord: Sendable, Equatable {
    let name: String
    let arguments: String
    let isError: Bool
    let errorCode: String?

    init(name: String, arguments: String, isError: Bool = false, errorCode: String? = nil) {
        self.name = name
        self.arguments = arguments
        self.isError = isError
        self.errorCode = errorCode
    }
}
