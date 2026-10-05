import Foundation

// MARK: - Skill 模型（SKILL.md + 远端索引）
//
// Skill 与「模块（JS 插件）」的区别（这段是它存在的理由，别和模块搞混）：
//   模块 = 可执行的函数：tools.js 注册工具 → 进工具目录 → 模型调用它干活；
//   skill = 按需加载的**说明**：模型先只看得到「名字 + 什么时候该用」，
//           判断这次任务命中，才用 load_skill 把正文拉进上下文再动手。
// 前者回答「能做什么动作」，后者回答「这件事该怎么做」。
//
// 安全前提沿用模块那一套（skill 同样是"别人写的、要进我上下文"的内容）：
// ① id 过白名单（id 会被拼成落盘目录，能穿越就等于任意写盘）；
// ② SKILL.md 的 sha256 在写盘前强校验；
// ③ 资源文件路径必须锁在 skill 目录内 —— 落点在 SkillStore.safeAssetPath / assetURL。

/// 一个 skill 的元信息（来自 SKILL.md 的 frontmatter）。
struct SkillManifest: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    /// 一句话说明「这是什么、什么时候该用它」。它会被注入模型目录 ——
    /// 写不清楚就等于这个 skill 不存在：模型没有任何别的线索能判断该不该加载它。
    var description: String
    /// 更细的触发条件（可选），会跟在 description 后面一起给模型。
    var whenToUse: String?
    var version: String
    var author: String?
    var minAppVersion: String?
}

/// SKILL.md 的解析结果：元信息 + 给模型的正文。
struct ParsedSkill: Sendable {
    let manifest: SkillManifest
    /// frontmatter 之后的正文，即「这件事该怎么做」的说明。
    let body: String
}

enum SkillFile {

    private static let fence = "---"

    /// 解析 SKILL.md。
    ///
    /// 格式刻意做得极简（只有 `key: value` 单行值，不支持嵌套 / 多行 / 列表），原因：
    /// 为了读 6 个短字段而引入一个 YAML 解析器，等于给「用户手写的文本」开一个更大的
    /// 解析面（锚点、标签、多行折叠、类型转换全得跟着处理，出错时还只能报一句解析异常）。
    /// 这里需要的表达能力只有几个短字段，单行 key: value 足够，且失败时能说清缺了什么。
    static func parse(_ text: String) -> ParsedSkill? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var i = 0
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        // 没有 frontmatter 直接判失败：宁可明确报错，也不去猜哪一行是元信息哪一行是正文。
        guard i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) == fence else { return nil }
        i += 1

        var fields: [String: String] = [:]
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces) != fence {
            let line = lines[i]
            i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon])
                .trimmingCharacters(in: .whitespaces).lowercased()
            let value = unquote(String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces))
            if !key.isEmpty { fields[key] = value }
        }
        // frontmatter 没闭合（走完了所有行都没遇到第二个 ---）
        guard i < lines.count else { return nil }
        let body = lines[(i + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let id = fields["id"], !id.isEmpty,
              let name = fields["name"], !name.isEmpty,
              let desc = fields["description"], !desc.isEmpty
        else { return nil }

        return ParsedSkill(
            manifest: SkillManifest(
                id: id,
                name: name,
                description: desc,
                whenToUse: nonEmpty(fields["when_to_use"]),
                version: nonEmpty(fields["version"]) ?? "1.0.0",
                author: nonEmpty(fields["author"]),
                minAppVersion: nonEmpty(fields["min_app_version"])
            ),
            body: body
        )
    }

    /// 把 manifest + body 重新拼成 SKILL.md（落盘 / 导出用）。
    ///
    /// 关键点：单行字段必须先压掉换行。用户完全可能在 description 里敲一次回车，
    /// 那会让这个字段跨行 —— 文件本身还写得出，但下次 parse 时它只读到第一行，
    /// 后半个字段变成"正文"，而且不报任何错。这里直接归一化，从源头杜绝。
    static func render(manifest: SkillManifest, body: String) -> String {
        var lines = [fence,
                     "id: \(oneLine(manifest.id))",
                     "name: \(oneLine(manifest.name))",
                     "description: \(oneLine(manifest.description))"]
        if let w = nonEmpty(manifest.whenToUse) { lines.append("when_to_use: \(oneLine(w))") }
        lines.append("version: \(oneLine(manifest.version))")
        if let a = nonEmpty(manifest.author) { lines.append("author: \(oneLine(a))") }
        if let m = nonEmpty(manifest.minAppVersion) { lines.append("min_app_version: \(oneLine(m))") }
        lines.append(fence)
        return lines.joined(separator: "\n") + "\n\n" + body + "\n"
    }

    private static func oneLine(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// 去掉包裹的引号（`"x"` / `'x'`）
    private static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let quoted = (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'"))
        return quoted ? String(s.dropFirst().dropLast()) : s
    }
}

// MARK: - 远端技能索引（skills/index.json）

/// 索引条目。与模块的 ModuleIndexEntry 同构（含 sha256 强锚点的语义），
/// 但少了 permissions —— skill 不执行代码、不联网、不写盘，没有权限可声明。
struct SkillIndexEntry: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    var minAppVersion: String?
    /// SKILL.md 的下载地址
    var skill: String
    /// SKILL.md 的 sha256（强锚点）。与模块同理：索引在另一条通道上，
    /// 控制了 raw 主机的对手改不动它。缺失时按"兼容优先"安装，但明确提示用户。
    var sha256: String?
    /// 可选资源文件（模板、参考文档等），落盘在 <skill>/<path>
    var assets: [Asset]?

    struct Asset: Codable, Sendable, Identifiable {
        var path: String
        var url: String
        var sha256: String?
        var id: String { path }
    }
}

struct SkillIndex: Codable, Sendable {
    var skills: [SkillIndexEntry]
}

/// 技能安装/更新状态（UI 用）
struct SkillUpdate: Identifiable, Sendable {
    let entry: SkillIndexEntry
    /// nil = 未安装；非 nil = 已安装的版本
    let installedVersion: String?
    var id: String { entry.id }
    var hasUpdate: Bool { installedVersion != entry.version }
}