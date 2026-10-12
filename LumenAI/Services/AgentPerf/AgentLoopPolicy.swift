import Foundation

// MARK: - Agent 主循环的终止策略（纯逻辑，可单独测试）
//
// 为什么把「循环什么时候可以停」从 AgentService 里抽出来：
// 这块逻辑原来是散在 `run()` 的十几个出口里的（结束暗号 / 纯正文兜底 / 空转检测 /
// 软上限 / 取消），每一处都自己判断、自己 return。结果是：
//   · 出口之间不一致 —— 有的出口清了断点存档，有的没清；
//   · 无法测试 —— 想验证"答案出了还会不会再请求模型"就必须把整个 App 跑起来；
//   · 加新出口时最容易漏（漏掉的那一个就是线上那个 bug）。
//
// 现在这些判定收在一个纯值类型里（Foundation-only、无 UI、无网络、无单例），
// 因此 `tests/agent_loop/main.swift` 可以用脚本文本直接驱动它，断言
// **模型请求次数 / 终止原因 / 是否清档** —— 这三件正是用户报告里说不清的那三件。

// MARK: 终止原因

/// 本次 run 为什么结束。
///
/// 每一个 case 都对应一个**明确的运行状态**（而不是"输出里有没有某个字符串"）：
/// 只有下面这些原因才意味着"任务真的结束了"，其余（取消 / 生成失败）都必须保留
/// 断点存档以便续跑。
enum AgentTerminalReason: String, Equatable, Sendable {
    /// 模型给出了结束暗号 + 正文（正常收尾）。
    case endSignal
    /// 模型给了结束暗号但正文为空（生成被截断）。只允许再补一次正文，之后必须收尾。
    case endSignalWithoutBody
    /// 连续两轮纯正文高度相似 → 模型其实已经答完，只是没按约定给暗号。
    case plainTextAnswer
    /// 连续多轮纯正文（内容不相似）→ 模型没有推进也没有收尾，直接以最后一段正文收尾。
    case plainTextStreak
    /// 连续多轮空回复（既无暗号也无正文）→ 不可能靠继续请求变好。
    case emptyOutput
    /// 同一批工具调用用同一组参数反复发送 → 结果不可能改变。
    case repeatToolCalls
    /// 到达软轮次上限。
    case softLimit
    /// 任务被取消（切后台被系统收走 / 用户停止）—— **不是**完成。
    case cancelled

    /// 这个出口是否意味着「任务已经结束、可以清掉断点存档」。
    ///
    /// 这就是 P0 的核心修订之一：以前只有"跑完 while 循环"那一条路会清档，
    /// 而"出了最终答案后 return"的那几条路**全都漏了** —— 断点存档留在盘上，
    /// 下次前台化/冷启动就被当成"被打断的任务"自动续跑一遍：
    /// 用户看到的是"答案都出来了，它还在继续跑、还在请求模型"。
    var clearsCheckpoint: Bool {
        switch self {
        case .endSignal, .endSignalWithoutBody, .plainTextAnswer,
             .plainTextStreak, .emptyOutput, .repeatToolCalls, .softLimit:
            return true
        case .cancelled:
            return false
        }
    }

    /// 给用户/日志看的一句短说明。
    var label: String {
        switch self {
        case .endSignal:            return "模型给出结束暗号"
        case .endSignalWithoutBody: return "只有结束暗号、没有正文"
        case .plainTextAnswer:      return "连续两轮相同的结论（未出暗号）"
        case .plainTextStreak:      return "连续多轮只有正文、没有动作"
        case .emptyOutput:          return "连续空回复"
        case .repeatToolCalls:      return "同一批工具调用反复重复"
        case .softLimit:            return "到达轮次软上限"
        case .cancelled:            return "任务被取消"
        }
    }
}

// MARK: 策略

/// 主循环的可调策略。
///
/// `fixed` = 本次修复后的线上行为；`legacy` = 修复前的行为（用于 A/B 复现与回滚验证）。
/// 之所以把"修复前"也留成一份可实例化的策略：性能对比必须能在**同一份代码**上
/// 跑出改前/改后两个数，否则"优化了多少"就只是叙事。
struct AgentLoopPolicy: Sendable, Equatable {

    /// 软轮次上限（防死循环兜底，不是"任务该跑多少轮"）。
    var softIterationLimit: Int = 150

    /// 连续「纯正文」轮的硬上限。
    ///
    /// 纯正文轮 = 既没出结束暗号、也没给出可执行工具调用的轮次 —— 也就是模型
    /// "没动作"的轮次。修复前这个阈值是 4（且要求两轮内容**高度相似**），
    /// 于是"模型已经写出结论、只是没给暗号"这个最常见的收尾形态要多烧 1~3 次
    /// 完整请求（每次都要重发整段历史）。取 2 的取舍：模型已经连着两轮既没动作
    /// 也没收尾，说明它按当前上下文给不出下一步动作了，拿最后一段正文收尾比继续追问更接近用户预期。
    var maxPlainTextStreak: Int = 2

    /// 判定"两轮正文是不是同一个答案"的最小长度（归一化之后的字数）。
    /// 比修复前的 40 低：本地小模型的结论常常只有二三十字，40 会让它漏判。
    var similarityMinLength: Int = 24

    /// 「连续纯正文就算答完」所要求的长度（字数）。
    ///
    /// 为什么比相似度阈值大得多：这两个信号的可信度不一样。
    /// 「两轮内容相似」是很强的证据（模型在重复同一段话）；而「连续两轮没动作」
    /// 本身只是弱信号 —— 小模型常在纯正文里写"我看看 A，再看看 B"这种一步一句的推理，
    /// 把它当成结论就会**砍掉正在推进的任务**（用任务成功率换请求次数，正是这次优化明令禁止的）。
    /// 80 字的取舍：一句"我看看 X"够不着它，一段真正的结论（通常上百字）够得着。
    var answerLikeMinLength: Int = 80

    /// 用词袋（字符 bigram Jaccard）相似度阈值 —— 修复前只认"完全相同 / 前缀 / 包含"，
    /// 模型把同一段结论换个措辞重写就判不出来，于是继续空转。
    var similarityMinOverlap: Double = 0.6

    /// 是否启用词袋相似度（false 时退化为修复前的"前缀/包含"判定）。
    var usesBagOfWordsSimilarity: Bool = true

    /// 同名同参数的调用连续多少次就中止本轮 run。
    var repeatToolCallLimit: Int = 3

    /// 连续多少轮"只有结束暗号、没有正文"就收尾（不再请求模型）。
    ///
    /// 取 2 = 允许**补一次**正文，第二次仍没有就停。修复前没有这条规则 ——
    /// 于是"模型只吐一个暗号"会一直请求下去（每轮都是完整 prompt）直到轮次上限，
    /// 用户看到的是"答案不出来、它一直在转"。legacy 用 `Int.max` 复现这个行为。
    var maxSignalOnlyRounds: Int = 2

    /// 流式生成里看到结束暗号时，是否立刻掐断这一轮。
    ///
    /// 修复前是 true —— 而这是"答案永远出不来、于是无限循环"的根源：
    /// 提示词要求模型**先输出暗号、再输出正文**，所以在暗号处掐断，恰好把
    /// 正文（用户唯一想看到的东西）全部扔掉；随后的 `extractFinalAnswer`
    /// 拿到"只有暗号没有正文"→ 返回 nil → 本轮被判成"纯思考" → 继续下一轮 → 再掐一次。
    /// 线上表现为"答案一直不出来，agent 一直在转"。
    var stopStreamAtEndSignal: Bool = false

    /// 暗号之后最多再收多少**字符**（0 = 不限制）。
    ///
    /// 不立刻掐断不等于放任：万一模型在暗号后进入失控长写（重复贴日志之类），
    /// 这里给一个上限，超过就停 —— 是"防跑飞"，不是"省 tokens"。
    var maxTailCharactersAfterSignal: Int = 8192

    /// 连续空回复多少次就收尾。
    var maxEmptyRounds: Int = 2

    /// 连续「无动作纯正文」轮的**硬上限**（0 = 不限制）。
    ///
    /// 为什么在"相似即可收尾"之外还要有它：相似度判据要求归一化后 ≥ `similarityMinLength`(24)，
    /// 而"连续多轮无动作"那条又要求 ≥ `answerLikeMinLength`(80)。于是**又短又不带暗号的结论**
    /// （如"已完成，文件在 /tmp/a.txt"）两边都够不着 —— 循环会把同一段历史重发到软上限 150 轮。
    /// 这正是用户报的"答案已经出来了、它还在请求模型"的残留形态。
    ///
    /// 主流开源编码 agent（Cline / Codex / OpenCode）的循环语义本来就是"本轮没有工具调用 = 结束"；
    /// 这里取更保守的 3：允许模型连着两轮"只是想想"，第 3 轮还不动手就拿最后一段正文收尾。
    var plainTextHardLimit: Int = 3

    /// 是否在"任务真的结束"的出口清掉断点存档（见 `AgentTerminalReason.clearsCheckpoint`）。
    /// 修复前为 false —— 也就是那个"答案出完还会自己复活再跑一遍"的 bug。
    var clearCheckpointOnFinish: Bool = true

    /// 修复后的线上策略。
    static let fixed = AgentLoopPolicy()

    /// 修复前的行为（仅用于复现与对比）。
    static let legacy: AgentLoopPolicy = {
        var p = AgentLoopPolicy()
        p.maxPlainTextStreak = 4
        p.similarityMinLength = 40
        p.answerLikeMinLength = 40
        p.usesBagOfWordsSimilarity = false
        p.maxSignalOnlyRounds = Int.max
        p.stopStreamAtEndSignal = true
        p.maxTailCharactersAfterSignal = 0
        p.maxEmptyRounds = Int.max          // 修复前没有这条兜底
        p.plainTextHardLimit = Int.max      // 修复前：短正文结论可以一路重发到软上限
        p.clearCheckpointOnFinish = false
        return p
    }()
}

// MARK: 判定结果

/// 一轮「纯正文」的判定结果。
enum AgentPlainRoundVerdict: Equatable {
    /// 继续循环（附当前连续纯正文轮数，供 UI/日志）。
    case keepThinking(streak: Int)
    /// 就以这段正文收尾。
    case finishAsAnswer(String, AgentTerminalReason)
}

/// 一轮「出现结束暗号」的判定结果。
enum AgentSignalVerdict: Equatable {
    /// 有正文 → 直接结束并返回正文。
    case finalAnswer(String)
    /// 只有暗号、没有正文 → 允许**一次**补正文的请求。
    case retryOnceForBody
    /// 补过之后仍然没有正文 → 用兜底文案收尾，不再请求模型。
    case finishWithoutBody(String)
}

/// 重复工具调用的判定结果。
enum AgentRepeatVerdict: Equatable {
    case proceed
    /// 已经重复（第 N 轮完全相同）→ 提示，但还继续。
    case warning(round: Int)
    /// 达到上限 → 中止本轮 run。
    case abort
}

// MARK: 终止状态机

/// Agent 主循环的终止状态机。
///
/// 它只做三件事：记账（第几轮 / 连续纯正文 / 连续重复调用）、判定（能不能停）、
/// 幂等地记住"已经停了，原因是 X"。所有会产生副作用的动作（发请求、执行工具、
/// 清档）仍由 AgentService 做 —— 这样它可以在测试里被完整驱动一遍。
struct AgentLoopTerminator: Sendable {
    let policy: AgentLoopPolicy

    /// 连续「纯正文」轮数。
    private(set) var plainTextStreak = 0
    /// 上一轮纯正文内容（用于相似度判定）。
    private(set) var lastPlainText: String?
    /// 连续空回复轮数。
    private(set) var emptyStreak = 0
    /// "只有暗号没有正文"出现过的次数。
    private(set) var signalOnlyRounds = 0
    /// 连续重复调用轮数。
    private(set) var repeatStreak = 0
    /// 云端：上一轮的调用签名集合（集合相等才算重复）。
    private(set) var lastRoundSignatures: Set<String>?
    /// 本地：上一次调用的签名。
    private(set) var lastCallSignature: String?
    /// 终止原因（nil = 还没结束）。
    private(set) var terminalReason: AgentTerminalReason?
    /// 终止时返回给调用方的正文。
    private(set) var finalAnswer: String?
    /// 记过的轮数（供指标与断言用）。
    private(set) var rounds = 0

    init(policy: AgentLoopPolicy = .fixed) {
        self.policy = policy
    }

    var isFinished: Bool { terminalReason != nil }

    /// 是否应该清掉断点存档。只有"任务真的结束"才为 true（取消 / 失败为 false）。
    var clearsCheckpointOnFinish: Bool {
        guard policy.clearCheckpointOnFinish, let reason = terminalReason else { return false }
        return reason.clearsCheckpoint
    }

    /// 记一轮（在真正发起模型请求之后调用）。
    mutating func beginRound() { rounds += 1 }

    /// 幂等地终止。重复调用只记第一次 —— 一次 run 里出现两个"完成"是 bug，不是特性。
    mutating func finish(_ reason: AgentTerminalReason, answer: String?) {
        guard terminalReason == nil else { return }
        terminalReason = reason
        finalAnswer = answer
    }

    /// 有真实动作（执行了工具调用）→ 纯正文 / 空回复计数清零。
    mutating func noteToolCall() {
        plainTextStreak = 0
        lastPlainText = nil
        emptyStreak = 0
    }

    /// 一轮纯正文（无暗号、无可执行工具调用）的判定。
    mutating func evaluatePlainRound(_ text: String) -> AgentPlainRoundVerdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            emptyStreak += 1
            if emptyStreak >= policy.maxEmptyRounds {
                let fallback = Self.emptyOutputFallback
                finish(.emptyOutput, answer: fallback)
                return .finishAsAnswer(fallback, .emptyOutput)
            }
            return .keepThinking(streak: plainTextStreak)
        }
        emptyStreak = 0

        let previous = lastPlainText
        let similar = previous.map {
            AgentAnswerSimilarity.isSameAnswer($0, trimmed, policy: policy)
        } ?? false
        plainTextStreak += 1
        lastPlainText = trimmed

        if similar {
            finish(.plainTextAnswer, answer: trimmed)
            return .finishAsAnswer(trimmed, .plainTextAnswer)
        }
        if plainTextStreak >= policy.maxPlainTextStreak,
           trimmed.count >= policy.answerLikeMinLength {
            finish(.plainTextStreak, answer: trimmed)
            return .finishAsAnswer(trimmed, .plainTextStreak)
        }
        // 硬上限：短正文也得收敛（理由见 plainTextHardLimit 的注释）。
        if policy.plainTextHardLimit > 0, plainTextStreak >= policy.plainTextHardLimit {
            finish(.plainTextStreak, answer: trimmed)
            return .finishAsAnswer(trimmed, .plainTextStreak)
        }
        return .keepThinking(streak: plainTextStreak)
    }

    /// 一轮出现结束暗号的判定。
    mutating func evaluateEndSignal(answer: String?) -> AgentSignalVerdict {
        if let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finish(.endSignal, answer: answer)
            return .finalAnswer(answer)
        }
        signalOnlyRounds += 1
        if signalOnlyRounds < policy.maxSignalOnlyRounds { return .retryOnceForBody }
        let fallback = Self.noBodyFallback
        finish(.endSignalWithoutBody, answer: fallback)
        return .finishWithoutBody(fallback)
    }

    /// 云端：一轮可能发多个调用 → 用**调用集合**判定重复。
    mutating func registerCallSet(_ signatures: Set<String>) -> AgentRepeatVerdict {
        if let last = lastRoundSignatures, last == signatures {
            repeatStreak += 1
        } else {
            repeatStreak = 0
        }
        lastRoundSignatures = signatures
        return repeatVerdict()
    }

    /// 本地：一轮只有一个调用 → 用**单个签名**判定重复。
    mutating func registerCallSignature(_ signature: String) -> AgentRepeatVerdict {
        if let last = lastCallSignature, last == signature {
            repeatStreak += 1
        } else {
            repeatStreak = 0
        }
        lastCallSignature = signature
        return repeatVerdict()
    }

    private func repeatVerdict() -> AgentRepeatVerdict {
        if repeatStreak + 1 >= policy.repeatToolCallLimit { return .abort }
        if repeatStreak >= 1 { return .warning(round: repeatStreak + 1) }
        return .proceed
    }

    // MARK: 兜底文案（集中一处，测试可断言）

    /// 连续空回复的兜底。原来这种情况会一直请求模型直到软上限（150 轮）——
    /// 每轮都是一次完整 prompt，烧钱且永远不会有结果。
    static let emptyOutputFallback = """
    ⚠️ 模型连续多轮没有输出任何内容（空回复），已停止本次运行。
    可以重新发送一次，或换一个模型再试。
    """

    /// 只有暗号没有正文的兜底。
    static let noBodyFallback = """
    ⚠️ 模型只输出了结束标记、没有给出回答正文（多半是生成被截断）。
    已停止本次运行 —— 重新发送一次通常就好。
    """
}

// MARK: 答案相似度

/// 「两轮正文是不是同一个答案」的判定。
///
/// 为什么不能只比较字符串相等：模型（尤其小模型）经常把同一段结论换个措辞重写一遍 ——
/// 修复前只认"完全相同 / 前缀 / 包含"，于是这种"改写过的重复"被当成新的一轮推进，
/// 循环继续、请求继续、token 继续烧。
enum AgentAnswerSimilarity {

    /// 归一化：小写、去掉空白与标点。
    /// 只做这一步的好处是不改变语义 —— 标点与空白的差异本来就不影响"这是不是同一个答案"。
    static func normalize(_ text: String) -> String {
        var out = String()
        out.reserveCapacity(text.count)
        for ch in text.lowercased() {
            if ch.isWhitespace || ch.isPunctuation || ch.isSymbol { continue }
            out.append(ch)
        }
        return out
    }

    /// 字符 bigram 的 Jaccard 相似度（0…1）。
    /// 单字符（长度 1）退化为是否相等，避免 bigram 集合为空导致除零。
    static func overlap(_ a: String, _ b: String) -> Double {
        let sa = Array(a), sb = Array(b)
        if sa.count < 2 || sb.count < 2 { return a == b ? 1 : 0 }
        var setA = Set<String>()
        var setB = Set<String>()
        setA.reserveCapacity(sa.count)
        setB.reserveCapacity(sb.count)
        for i in 0..<(sa.count - 1) { setA.insert(String([sa[i], sa[i + 1]])) }
        for i in 0..<(sb.count - 1) { setB.insert(String([sb[i], sb[i + 1]])) }
        let union = setA.union(setB).count
        guard union > 0 else { return 0 }
        return Double(setA.intersection(setB).count) / Double(union)
    }

    static func isSameAnswer(_ a: String, _ b: String, policy: AgentLoopPolicy) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        guard min(na.count, nb.count) >= policy.similarityMinLength else { return false }
        if na == nb { return true }
        let short = na.count <= nb.count ? na : nb
        let long = na.count <= nb.count ? nb : na
        if long.hasPrefix(short) || long.contains(short) { return true }
        guard policy.usesBagOfWordsSimilarity else { return false }
        return overlap(na, nb) >= policy.similarityMinOverlap
    }
}

// MARK: 结束暗号解析

/// Agent 结束暗号的解析（纯函数）。
enum AgentFinalAnswer {

    /// 检测暗号并提取最终回答。返回 nil 表示：没有暗号，**或**只有暗号没有正文。
    /// 兼容暗号在前（`暗号 + 正文`）与在后（`正文 + 暗号`）两种写法。
    static func extract(from text: String, endSignal: String) -> String? {
        guard contains(text, endSignal: endSignal) else { return nil }
        let cleaned = text
            .replacingOccurrences(of: endSignal, with: "\n", options: [.caseInsensitive])
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 只输出了暗号没有正文：交给上层兜底（见 AgentLoopTerminator.evaluateEndSignal）
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 是否出现了结束暗号（不区分大小写）。
    static func contains(_ text: String, endSignal: String) -> Bool {
        text.range(of: endSignal, options: [.caseInsensitive]) != nil
    }
}
