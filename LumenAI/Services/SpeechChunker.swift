import Foundation

/// 把要朗读的文本切成**适合逐句合成**的片段。
///
/// 为什么需要它：CosyVoice3 是自回归模型 —— 先逐 token 生成语音 token，
/// 再过 flow matching，再过 HiFi-GAN，**整段文本全部生成完才可能出声**。
/// 一条几百字的回复在手机上要几十秒才合成完，用户感知就是「点了半天没反应」。
///
/// 切成句子后，合成完第一句就能开播，其余句子在播放期间继续合成 ——
/// 出声时间从「整段」降到「一句」，而且是流式听感。
///
/// 分片大小是个权衡：
///   · 太小 → 每片都要走一次完整前向 + 一次 flow/HiFi-GAN，碎片多了总开销上升，
///            而且句间停顿会变密；
///   · 太大 → 首句出声变慢，又回到原来的问题。
enum SpeechChunker {

    /// 单句超过这个长度，就退而求其次在逗号 / 顿号处切。
    static let softLimit = 60
    /// 短于这个长度的片段会并入下一片。
    ///
    /// 为什么必须合并：每片都要走一次完整的模型前向。「嗯。」「好。」各自成片的话，
    /// 两次前向的代价远高于它省下的那几个字。
    static let minChunk = 10
    /// 没有任何标点的超长串（比如一整段英文无空格）只能硬切到这个上限。
    static let hardLimit = 120

    /// 句末标点（中英）。切在这些字符**之后**，标点本身保留在句尾 ——
    /// 去掉标点会让模型的韵律预测变差（它是在带标点的文本上训练的）。
    private static let sentenceEnders: Set<Character> = [
        "。", "！", "？", "…", "；", "!", "?", ";", "\n",
    ]

    /// 次级停顿：整句太长时退到这里切。
    private static let softBreakers: Set<Character> = [
        "，", "、", "：", ",", ":",
    ]

    /// 切分。返回的每一片都非空、且已去掉首尾空白。
    static func chunks(
        _ text: String,
        softLimit: Int = softLimit,
        hardLimit: Int = hardLimit
    ) -> [String] {
        let cleaned = sanitize(text)
        guard !cleaned.isEmpty else { return [] }

        var pieces: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }

        for character in cleaned {
            current.append(character)

            if sentenceEnders.contains(character) {
                flush()
                continue
            }
            // 已经够长了，遇到逗号级别的停顿就先切
            if current.count >= softLimit, softBreakers.contains(character) {
                flush()
                continue
            }
            // 连停顿都没有的长串：硬切，否则这一片会无限长下去
            if current.count >= hardLimit {
                flush()
            }
        }
        flush()

        return mergeShort(pieces)
    }

    /// 把过短的片段并入相邻片段（向后合并，避免出现孤零零的开头碎片）。
    private static func mergeShort(_ pieces: [String], minChunk: Int = minChunk) -> [String] {
        var out: [String] = []
        var pending = ""
        for piece in pieces {
            pending += piece
            if pending.count >= minChunk {
                out.append(pending)
                pending = ""
            }
        }
        if !pending.isEmpty {
            if let last = out.last {
                out[out.count - 1] = last + pending
            } else {
                out.append(pending)
            }
        }
        return out
    }

    /// 去掉 Markdown 标记。
    ///
    /// 朗读时不该把 `**`、`#`、反引号念出来；代码块更是念了也没意义
    /// （而且模型多半会念错）。所以这里把代码块整个替换成一句说明，
    /// 其余标记只去掉符号、保留文字。
    static func sanitize(_ text: String) -> String {
        var s = text

        // 代码围栏：整块替换成说明。保留一句是为了让"纯代码回复"仍然有声音 ——
        // 否则切出来是空的，用户点了朗读却什么都没发生。
        s = s.replacingOccurrences(
            of: "```[\\s\\S]*?```", with: "（代码块）", options: [.regularExpression])
        s = s.replacingOccurrences(
            of: "~~~[\\s\\S]*?~~~", with: "（代码块）", options: [.regularExpression])
        // 行内代码：留内容、去反引号
        s = s.replacingOccurrences(
            of: "`([^`]*)`", with: "$1", options: [.regularExpression])
        // 图片整块丢掉（alt 文本念出来是噪音）
        s = s.replacingOccurrences(
            of: "!\\[[^\\]]*\\]\\([^)]*\\)", with: "", options: [.regularExpression])
        // 链接只留文字
        s = s.replacingOccurrences(
            of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: [.regularExpression])
        // 强调 / 删除线
        s = s.replacingOccurrences(
            of: "\\*\\*([^*]+)\\*\\*", with: "$1", options: [.regularExpression])
        s = s.replacingOccurrences(
            of: "__([^_]+)__", with: "$1", options: [.regularExpression])
        s = s.replacingOccurrences(
            of: "\\*([^*\n]+)\\*", with: "$1", options: [.regularExpression])
        s = s.replacingOccurrences(
            of: "~~([^~]+)~~", with: "$1", options: [.regularExpression])
        // 行首标题井号
        s = s.replacingOccurrences(
            of: "(?m)^#{1,6}[ \\t]*", with: "", options: [.regularExpression])
        // 表格分隔行（|---|:--:|）本身没有可读内容
        s = s.replacingOccurrences(
            of: "(?m)^[ \\t]*\\|?[ \\t]*:?-{3,}:?[ \\t]*(\\|[ \\t]*:?-{3,}:?[ \\t]*)*\\|?[ \\t]*$",
            with: "", options: [.regularExpression])
        // 列表符号与有序列表编号
        s = s.replacingOccurrences(
            of: "(?m)^[ \\t]*[-*+][ \\t]+", with: "", options: [.regularExpression])
        s = s.replacingOccurrences(
            of: "(?m)^[ \\t]*[0-9]{1,2}\\.[ \\t]+", with: "", options: [.regularExpression])
        // 引用号
        s = s.replacingOccurrences(
            of: "(?m)^[ \\t]*>[ \\t]?", with: "", options: [.regularExpression])

        // 收尾：把连续空白与空行压掉，但保留换行（换行是切句依据之一）
        s = s.replacingOccurrences(of: "[ \\t]+", with: " ", options: [.regularExpression])
        s = s.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: [.regularExpression])
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
