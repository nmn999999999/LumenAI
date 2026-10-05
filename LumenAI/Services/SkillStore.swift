import Foundation
import CryptoKit

/// 技能包管理器：Documents/Skills/<id>/（SKILL.md + 可选资源文件）。
///
/// 与 `PluginManager` 的关系：**平行的第二条通道，不是它的子类**。
/// 模块那套的产物是可执行工具，skill 的产物是可注入的说明文本；两者唯一共享的是
/// "从外面装东西进来"这件事的**安全约定**（id 白名单 / sha256 完整性 / 落盘范围）。
/// 那几个校验函数因此直接复用 `PluginManager` 上的静态实现，而不是在这儿再抄一份 ——
/// 安全判定一旦有第二份实现，早晚会漂移成"绕开另一份的那一侧"。
///
/// 可见范围（产品决定，写在这里免得后人以为是漏了）：skill **只对云端模型生效**。
/// 原因是本地模型的 system prompt 与工具目录是训练契约（见 AgentService.withToolInstructions
/// 上方那段注释），往里塞它没见过的目录会直接掉效果；MCP / 插件工具也是同样待遇。
@MainActor
final class SkillStore: ObservableObject {

    static let shared = SkillStore()

    struct InstalledSkill: Identifiable, Sendable {
        let manifest: SkillManifest
        let directory: URL
        /// SKILL.md 正文
        let body: String
        /// 已归一化的资源文件相对路径（相对 skill 目录）
        let assets: [String]
        var id: String { manifest.id }
    }

    @Published private(set) var skills: [InstalledSkill] = []
    @Published private(set) var remoteIndex: [SkillIndexEntry] = []
    @Published private(set) var isChecking = false
    @Published var lastCheckError: String?
    /// 安装成功但"有话要说"（例如索引没提供 sha256）。与模块那边同一语义：
    /// 它是提示，不是失败 —— 塞进错误通道会让用户看到"安装失败"却发现已经装好了。
    @Published private(set) var installNotice: String?

    /// 存的是**被关掉的** id，而不是启用的：新装的 skill 天然处于启用态，
    /// 否则"装完还要再去开一次"会让人以为没装上。
    @Published private var disabledIDs: Set<String>

    private let skillsDir: URL
    private let indexURL = "https://raw.githubusercontent.com/nmn999999999/LumenAI/main/skills/index.json"
    private let disabledKey = "skills.disabled.v1"

    /// 暴露给模型的三个工具名（执行分发与目录注入都用它，避免两处各写一份字面量）
    static let toolNames: Set<String> = ["list_skills", "load_skill", "read_skill_file"]
    /// read_skill_file 的返回上限：资源是往上下文里灌的，必须封顶。
    private static let assetReadCap = 64 * 1024

    var updatableCount: Int { updateStates().filter(\.hasUpdate).count }
    var enabledSkills: [InstalledSkill] { skills.filter { isEnabled($0.id) } }

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        skillsDir = docs.appendingPathComponent("Skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        disabledIDs = Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
        loadAll()
    }

    // MARK: - id / 路径（全部落盘与读取都必须过这里）

    /// 复用模块的 id 白名单。规则必须**完全一致**：同一个恶意 id 不该在一条通道上被拦、
    /// 在另一条上放行。
    static func safeSkillID(_ raw: String) -> String? { PluginManager.safeModuleID(raw) }

    /// 由 id 得到 skill 目录。两道检查缺一不可：白名单 + 拼出来必须落在 Skills 之内
    /// （防住白名单将来被改错、或 Skills 下被人放了指向外部的软链）。
    private func skillDirectory(_ rawID: String) throws -> URL {
        guard Self.safeSkillID(rawID) != nil else { throw PluginManager.invalidIDError(rawID) }
        let dir = skillsDir.appendingPathComponent(rawID, isDirectory: true)
        let base = skillsDir.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = dir.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base + "/") else { throw PluginManager.invalidIDError(rawID) }
        return dir
    }

    /// 资源相对路径的归一化。拒绝：绝对路径、空段、`.`、`..`、超长。
    ///
    /// 为什么单独抽出来：它是 `read_skill_file` 的**唯一入口**，而那个工具的 path 参数
    /// 来自模型（也就是可能来自它读到的网页内容）。少了这一层，`../../Documents/xxx`
    /// 就能把沙盒里任意文本读进上下文。
    static func safeAssetPath(_ raw: String) -> String? {
        let p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p.count <= 200 else { return nil }
        guard !p.hasPrefix("/") else { return nil }
        let parts = p.components(separatedBy: "/")
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return parts.joined(separator: "/")
    }

    /// 资源文件绝对路径：归一化之后**再**确认落在该 skill 目录内（第二道防线）。
    func assetURL(skill: InstalledSkill, relativePath: String) throws -> URL {
        guard let safe = Self.safeAssetPath(relativePath) else {
            throw NSError(domain: "Skill", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "资源路径非法: \(relativePath.prefix(80))"
            ])
        }
        let url = skill.directory.appendingPathComponent(safe)
        let base = skill.directory.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base + "/") else {
            throw NSError(domain: "Skill", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "资源路径越界: \(relativePath.prefix(80))"
            ])
        }
        return url
    }

    // MARK: - 本地加载

    private func loadAll() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) else { return }
        var loaded: [InstalledSkill] = []
        for dir in dirs where dir.hasDirectoryPath {
            if let skill = loadSkill(at: dir) { loaded.append(skill) }
        }
        skills = loaded.sorted { $0.manifest.name < $1.manifest.name }
    }

    private func loadSkill(at dir: URL) -> InstalledSkill? {
        let dirID = dir.lastPathComponent
        guard let safeDirID = Self.safeSkillID(dirID) else {
            print("[skill] 跳过非法目录: \(dirID.prefix(60))")
            return nil
        }
        let mdURL = dir.appendingPathComponent("SKILL.md")
        guard let text = try? String(contentsOf: mdURL, encoding: .utf8),
              let parsed = SkillFile.parse(text)
        else { return nil }
        // 目录名与 frontmatter 的 id 必须一致。只靠安装口把关不够：备份恢复、外部拷进来的
        // 目录同样会进内存，而不一致的 id 会一路带进模型目录与工具参数。
        guard Self.safeSkillID(parsed.manifest.id) == safeDirID else {
            print("[skill] 跳过 id 不一致的目录: \(dirID) (frontmatter id=\(parsed.manifest.id.prefix(40)))")
            return nil
        }
        return InstalledSkill(manifest: parsed.manifest,
                              directory: dir,
                              body: parsed.body,
                              assets: assetList(in: dir))
    }

    /// 列出资源文件相对路径（排除 SKILL.md 与隐藏文件）
    private func assetList(in dir: URL) -> [String] {
        var out: [String] = []
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return out }
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            let rel = String(path.dropFirst(base.count + 1))
            guard rel != "SKILL.md", !rel.hasPrefix("."), !rel.contains("/.") else { continue }
            out.append(rel)
        }
        return out.sorted()
    }

    // MARK: - 落盘（唯一写盘点）

    private func write(manifest: SkillManifest, body: String, assets: [(path: String, data: Data)]) throws {
        let dir = try skillDirectory(manifest.id)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 覆盖式安装：先清掉旧内容，否则上一版的参考文档会以"幽灵文件"的形式留下，
        // 模型按 load_skill 返回的清单读到的可能是已经不存在的版本的内容。
        if let existing = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in existing { try? fm.removeItem(at: f) }
        }
        let md = SkillFile.render(manifest: manifest, body: body)
        try Data(md.utf8).write(to: dir.appendingPathComponent("SKILL.md"), options: .atomic)

        for asset in assets {
            guard let safe = Self.safeAssetPath(asset.path) else {
                throw NSError(domain: "Skill", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "资源路径非法: \(asset.path.prefix(60))"
                ])
            }
            let dest = dir.appendingPathComponent(safe)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try asset.data.write(to: dest, options: .atomic)
        }
        // 重新从磁盘加载（而不是就地拼一个 InstalledSkill）：装上去的东西和下次启动读到的东西
        // 必须是同一条路径的产物，否则"这次能读、重启就没了"这类问题查不出来。
        if let reloaded = loadSkill(at: dir) {
            skills.removeAll { $0.id == reloaded.id }
            skills.append(reloaded)
            skills.sort { $0.manifest.name < $1.manifest.name }
        }
    }

    func remove(_ skill: InstalledSkill) {
        // 删除是破坏性操作，且用的是 skill.directory：先确认 id 合法、路径确实在 Skills 之内
        // （万一某天有人给 InstalledSkill 传了外部路径，这里不会跟着删掉用户别的东西）。
        guard Self.safeSkillID(skill.id) != nil else {
            print("[skill] 拒绝删除 id 非法的技能: \(skill.id.prefix(60))")
            return
        }
        let base = skillsDir.standardizedFileURL.resolvingSymlinksInPath().path
        let target = skill.directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard target.hasPrefix(base + "/") else {
            print("[skill] 拒绝删除 Skills 之外的路径: \(target)")
            return
        }
        try? FileManager.default.removeItem(at: skill.directory)
        skills.removeAll { $0.id == skill.id }
        disabledIDs.remove(skill.id)
        UserDefaults.standard.set(Array(disabledIDs), forKey: disabledKey)
    }

    // MARK: - 启用 / 关闭

    func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    func setEnabled(_ id: String, _ on: Bool) {
        if on { disabledIDs.remove(id) } else { disabledIDs.insert(id) }
        UserDefaults.standard.set(Array(disabledIDs), forKey: disabledKey)
    }

    // MARK: - 安装：远端索引

    func updateStates() -> [SkillUpdate] {
        remoteIndex.map { entry in
            SkillUpdate(entry: entry,
                        installedVersion: skills.first { $0.id == entry.id }?.manifest.version)
        }
    }

    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: indexURL) else {
            lastCheckError = "无效的技能索引地址"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("LumenAI-iOS/skill", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                lastCheckError = "技能索引响应异常 (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))"
                return
            }
            remoteIndex = try JSONDecoder().decode(SkillIndex.self, from: data).skills
            lastCheckError = nil
        } catch {
            lastCheckError = "检查失败: \(error.localizedDescription.prefix(60))"
        }
    }

    /// 从索引安装/更新（返回错误文案；nil = 成功）
    func installFromIndex(_ entry: SkillIndexEntry) async -> String? {
        guard Self.safeSkillID(entry.id) != nil else {
            // 这个字符串会原样进 UI 的 alert，所以不 throw（throw 会被下面 catch 截到 60 字）
            return "技能 id 非法: \(entry.id.prefix(60))（只允许字母数字 . _ -，不能以点开头），已拒绝安装"
        }
        guard let mdURL = URL(string: entry.skill) else { return "无效的技能地址" }
        // 每次重新安装都先清掉上一条提示，否则上一次"未经校验"的警告会挂到这一次（校验通过的）安装上
        installNotice = nil
        do {
            let (mdData, mdResp) = try await URLSession.shared.data(from: mdURL)
            guard (mdResp as? HTTPURLResponse)?.statusCode == 200,
                  let mdText = String(data: mdData, encoding: .utf8)
            else { return "SKILL.md 下载失败" }

            // 完整性校验必须在**写盘之前**（下面 write 是唯一落盘点）
            var warning: String?
            if let expected = Self.declaredDigest(entry.sha256) {
                guard PluginManager.digestMatches(mdData, expected: expected) else {
                    return "技能校验失败: SKILL.md 的 sha256 不匹配"
                }
            } else {
                warning = "该技能未提供 sha256 校验值，已按兼容策略安装（内容未经完整性校验）。"
                print("[skill] \(entry.id): ⚠ 索引没有 sha256，按兼容策略放行（未校验完整性）")
            }

            guard let parsed = SkillFile.parse(mdText) else {
                return "SKILL.md 格式错误：缺少 frontmatter（需要 --- 包裹的 id / name / description）"
            }
            guard parsed.manifest.id == entry.id else {
                return "技能 frontmatter 的 id(\(parsed.manifest.id.prefix(40))) 与索引 id(\(entry.id.prefix(40))) 不一致，已拒绝安装"
            }
            if let blocked = Self.versionGate(parsed.manifest.minAppVersion) { return blocked }

            // 资源文件：逐个下载 + 校验（有 sha256 才校验）。任一失败即中止 ——
            // 不落"半个技能包"，因为残缺的资源会让模型按清单去读一个不存在的文件。
            var files: [(path: String, data: Data)] = []
            for asset in entry.assets ?? [] {
                guard let safePath = Self.safeAssetPath(asset.path) else {
                    return "资源路径非法: \(asset.path.prefix(60))"
                }
                guard let url = URL(string: asset.url) else { return "无效的资源地址: \(asset.path.prefix(60))" }
                let (data, resp) = try await URLSession.shared.data(from: url)
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    return "资源下载失败: \(safePath)"
                }
                if let expected = Self.declaredDigest(asset.sha256) {
                    guard PluginManager.digestMatches(data, expected: expected) else {
                        return "技能校验失败: \(safePath) 的 sha256 不匹配"
                    }
                }
                files.append((safePath, data))
            }

            try write(manifest: parsed.manifest, body: parsed.body, assets: files)
            installNotice = warning
            return nil
        } catch {
            return "安装失败: \(error.localizedDescription.prefix(60))"
        }
    }

    // MARK: - 安装：本地导入

    /// 本地导入：只认单个 SKILL.md 文本（iOS 的文件选择器交给我们的是一个文件）。
    /// 需要附资源文件的技能走远端索引那条路 —— 本地导入没有"多文件"的表达能力，
    /// 硬要支持就得先定一个压缩包格式，那是另一件事（模块那边用 .localaimod 做过）。
    @discardableResult
    func importLocalText(_ text: String) throws -> String? {
        guard let parsed = SkillFile.parse(text) else {
            throw NSError(domain: "Skill", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "SKILL.md 格式错误：缺少 frontmatter（需要 --- 包裹的 id / name / description）"
            ])
        }
        // 本地包也要清洗 id：它是"别人发给我、我手动选进来"的文件，里面同样可能写着 ../..
        guard Self.safeSkillID(parsed.manifest.id) != nil else {
            throw PluginManager.invalidIDError(parsed.manifest.id)
        }
        if let blocked = Self.versionGate(parsed.manifest.minAppVersion) {
            throw NSError(domain: "Skill", code: 2, userInfo: [NSLocalizedDescriptionKey: blocked])
        }
        try write(manifest: parsed.manifest, body: parsed.body, assets: [])
        return nil
    }

    // MARK: - Agent 集成

    func toolDefinitions() -> [AgentToolDefinition] {
        [
            AgentToolDefinition(
                id: "list_skills",
                name: "list_skills",
                description: "列出当前已启用的技能包：名字、一句话说明、何时使用、附带资源。技能是**按需加载**的说明文档 —— 不确定某个任务该不该用技能时先调它看一眼。只读，无副作用。",
                parameters: [:],
                requiresApproval: false
            ),
            AgentToolDefinition(
                id: "load_skill",
                name: "load_skill",
                description: "读取某个技能的完整说明正文，返回正文 + 该技能附带资源文件的路径清单。任务命中某个技能时**先调用它**，再按正文里的步骤办事。",
                parameters: [
                    "id": .init(type: "string", description: "技能 id（取自 list_skills 或系统提示里的技能清单）", enumValues: nil)
                ],
                requiresApproval: false
            ),
            AgentToolDefinition(
                id: "read_skill_file",
                name: "read_skill_file",
                description: "读取技能包内附带的资源文件（模板、参考文档等），路径取自 load_skill 返回的清单。只读，且只能读到该技能目录内的文件。",
                parameters: [
                    "id": .init(type: "string", description: "技能 id", enumValues: nil),
                    "path": .init(type: "string", description: "相对技能目录的文件路径，如 templates/report.md", enumValues: nil)
                ],
                requiresApproval: false
            ),
        ]
    }

    func hasTool(named name: String) -> Bool { Self.toolNames.contains(name) }

    /// 执行入口。@MainActor 由调用方（BuiltInTools.executeWithFallbacks）保证。
    func callTool(name: String, argumentsJSON: String) async -> String {
        var args: [String: Any] = [:]
        if let data = argumentsJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            args = obj
        }
        switch name {
        case "list_skills":
            return catalogText() ?? "错误: 当前没有已启用的技能。请让用户到「设置 → 技能」里安装或启用。"
        case "load_skill":
            return loadSkillText(id: (args["id"] as? String) ?? "")
        case "read_skill_file":
            return readSkillFile(id: (args["id"] as? String) ?? "",
                                 path: (args["path"] as? String) ?? "")
        default:
            return "错误: 未知工具: \(name)"
        }
    }

    /// 注入云端 prompt 的技能目录（渐进式披露第 1 层：只给"有什么、什么时候用"）。
    /// 返回 nil 表示没有启用任何技能 —— 调用方必须跳过整段注入，别塞一个空标题进去。
    func catalogText() -> String? {
        let enabled = enabledSkills
        guard !enabled.isEmpty else { return nil }
        let lines = enabled.map { skill -> String in
            var line = "- `\(skill.manifest.id)` — \(skill.manifest.description)"
            if let when = skill.manifest.whenToUse, !when.isEmpty {
                line += "（何时用：\(when)）"
            }
            if !skill.assets.isEmpty {
                let shown = skill.assets.prefix(6).joined(separator: ", ")
                line += "（含资源：\(shown)\(skill.assets.count > 6 ? " 等" : "")）"
            }
            return line
        }
        return lines.joined(separator: "\n")
    }

    private func loadSkillText(id: String) -> String {
        guard let skill = skills.first(where: { $0.id == id }) else {
            let available = enabledSkills.map(\.id).joined(separator: ", ")
            return "错误: 没有找到技能「\(id.prefix(60))」。可用技能: \(available.isEmpty ? "（无）" : available)"
        }
        guard isEnabled(skill.id) else {
            return "错误: 技能「\(skill.id)」已被用户关闭，不要使用它。"
        }
        var out = "# 技能: \(skill.manifest.name)（v\(skill.manifest.version)）\n\n\(skill.body)"
        if !skill.assets.isEmpty {
            out += "\n\n## 附带资源（用 read_skill_file 读取）\n"
                + skill.assets.map { "- \($0)" }.joined(separator: "\n")
        }
        return out
    }

    private func readSkillFile(id: String, path: String) -> String {
        guard let skill = skills.first(where: { $0.id == id }) else {
            return "错误: 没有找到技能「\(id.prefix(60))」"
        }
        guard isEnabled(skill.id) else { return "错误: 技能「\(skill.id)」已被用户关闭。" }
        guard !path.isEmpty else { return "错误: 缺少 path 参数（资源文件相对路径）" }
        do {
            let url = try assetURL(skill: skill, relativePath: path)
            let data = try Data(contentsOf: url)
            // 资源是往上下文里灌的，必须封顶：一份 5MB 的日志/PDF 会把上下文直接挤爆，
            // 而表现只是"模型突然变笨"，很难查。超限就让模型改用 file_op 那条路。
            guard data.count <= Self.assetReadCap else {
                return "错误: 资源文件过大（\(data.count) 字节 > \(Self.assetReadCap)）：\(path)。请改用 file_op 工具分段读取。"
            }
            guard let text = String(data: data, encoding: .utf8) else {
                return "错误: 资源不是 UTF-8 文本，无法读入上下文：\(path)"
            }
            return text
        } catch {
            return ToolResultFormat.errorPrefix + "读取失败: \(error.localizedDescription.prefix(80))"
        }
    }

    // MARK: - 小工具

    /// 只有"索引真的给了值"才算声明了校验值（空串/空白视为没给）
    private static func declaredDigest(_ raw: String?) -> String? {
        guard let raw, !PluginManager.normalizeDigest(raw).isEmpty else { return nil }
        return raw
    }

    /// minAppVersion 门槛。App 版本低于技能要求 → 返回拒绝文案（nil = 放行）
    private static func versionGate(_ required: String?) -> String? {
        guard let required, !required.isEmpty else { return nil }
        let app = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        guard UpdateCheckerService.compare(UpdateCheckerService.stripV(required), app) > 0 else { return nil }
        return "需要升级 App 到 v\(required) 才能安装此技能"
    }
}