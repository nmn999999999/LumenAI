import Foundation
import CryptoKit

/// 技能存储管理器
///
/// 设计目标：
/// - 技能存放于 Documents/Skills/<id>/（manifest.json），独立版本、独立更新
/// - 基础包（IPA）不动；技能更新在 App 内完成
/// - 远程索引：GitHub 仓库 skills/index.json
/// - 支持本地创建、编辑、导入、导出、分享
/// - 内置技能随 App 发布，用户可启用/禁用
///
/// 安全边界：
/// 1. **id 白名单**（safeSkillID）：防路径穿越
/// 2. **sha256 完整性**：远程安装必须校验
/// 3. **落盘前归一化兜底**：最终路径必须在 skillsDir 内
@MainActor
final class SkillStore: ObservableObject {

    static let shared = SkillStore()

    /// 已安装技能
    struct InstalledSkill: Identifiable, Sendable {
        let manifest: SkillManifest
        let directory: URL
        var id: String { manifest.id }
        var isBuiltIn: Bool { manifest.isBuiltIn }

        /// 技能是否因用户禁用而不可见
        var isEnabled: Bool { manifest.isEnabled }
    }

    @Published private(set) var skills: [InstalledSkill] = []
    @Published private(set) var remoteIndex: [SkillIndexEntry] = []
    @Published private(set) var isChecking = false
    @Published var lastCheckError: String?
    @Published private(set) var installNotice: String?

    /// 可更新技能数量（服务页角标）
    var updatableCount: Int {
        updateStates().filter(\.hasUpdate).count
    }

    /// 启动静默检查（1 天节流）
    private let lastCheckKey = "skill_check_ts"
    func checkForUpdatesIfNeeded() async {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= 86400 else { return }
        await checkForUpdates()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
    }

    private let skillsDir: URL
    /// 技能索引地址（GitHub raw；可换成自己的静态站点）
    private let indexURL = "https://raw.githubusercontent.com/nmn999999999/LumenAI/main/skills/index.json"

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        skillsDir = docs.appendingPathComponent("Skills", isDirectory: true)
        try? FileManager.default.createDirectory(at: skillsDir, withIntermediateDirectories: true)
        loadAll()
        // 注册内置技能
        registerBuiltInSkills()
    }

    // MARK: - id 清洗 / 完整性校验（安全工具，全部路径都必须过这里）

    /// 只允许 [A-Za-z0-9._-]，且拒绝 "."、".."、以点开头、长度 0 或 >64 的 id。
    /// 返回 nil 表示非法。
    static func safeSkillID(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 64 else { return nil }
        guard raw != ".", raw != "..", !raw.hasPrefix(".") else { return nil }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw
    }

    /// 非法 id 的统一错误
    static func invalidIDError(_ raw: String) -> NSError {
        NSError(domain: "Skill", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "技能 id 非法: \(raw.prefix(60))（只允许字母数字 . _ -，不能以点开头）"
        ])
    }

    /// 由 id 得到技能目录，两个检查缺一不可
    private func skillDirectory(_ rawID: String) throws -> URL {
        guard let id = Self.safeSkillID(rawID) else { throw Self.invalidIDError(rawID) }
        let dir = skillsDir.appendingPathComponent(id, isDirectory: true)
        let base = skillsDir.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = dir.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix(base + "/"), resolved != base else {
            throw Self.invalidIDError(rawID)
        }
        return dir
    }

    /// SHA256 十六进制（小写）
    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 期望值归一化
    static func normalizeDigest(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("sha256:") { s = String(s.dropFirst("sha256:".count)) }
        return s
    }

    /// 内容与声明值是否一致
    static func digestMatches(_ data: Data, expected: String) -> Bool {
        Self.sha256Hex(data) == Self.normalizeDigest(expected)
    }

    /// 只有"索引/清单真的给了值"才算声明了校验值
    private static func declaredDigest(_ raw: String?) -> String? {
        guard let raw, !Self.normalizeDigest(raw).isEmpty else { return nil }
        return raw
    }

    // MARK: - 本地加载

    private func loadAll() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) else { return }
        var loaded: [InstalledSkill] = []
        for dir in dirs {
            guard dir.hasDirectoryPath else { continue }
            if let skill = loadSkill(at: dir) {
                loaded.append(skill)
            }
        }
        skills = loaded.sorted { $0.manifest.name < $1.manifest.name }
    }

    private func loadSkill(at dir: URL) -> InstalledSkill? {
        let fm = FileManager.default
        let manifestURL = dir.appendingPathComponent("manifest.json")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(SkillManifest.self, from: manifestData)
        else { return nil }
        // 目录名与 manifest.id 必须都是合法 id 且一致
        guard let dirID = Self.safeSkillID(dir.lastPathComponent),
              Self.safeSkillID(manifest.id) == dirID
        else {
            print("[skill] 跳过非法技能目录: \(dir.lastPathComponent) (manifest.id=\(manifest.id))")
            return nil
        }
        // 内置技能的 manifest.json 在 bundle 里，不在 Documents/Skills，这里只加载用户技能
        return InstalledSkill(manifest: manifest, directory: dir)
    }

    // MARK: - 内置技能注册

    private func registerBuiltInSkills() {
        let builtInSkills = SkillManifest.builtInSkills()
        for builtIn in builtInSkills {
            // 内置技能不写入 Documents/Skills，只内存中存在
            // 如果用户之前安装过同 id 的技能，以用户版本为准
            if !skills.contains(where: { $0.id == builtIn.id }) {
                // 创建一个虚拟目录（内存中标记为内置）
                let virtualDir = skillsDir.appendingPathComponent("__builtin_\(builtIn.id)", isDirectory: true)
                skills.append(InstalledSkill(manifest: builtIn, directory: virtualDir))
            }
        }
        skills.sort { $0.manifest.name < $1.manifest.name }
    }

    // MARK: - 增删改

    /// 创建/更新技能（本地创建/编辑）
    func save(_ skill: SkillManifest) throws {
        // ① 唯一拼路径的地方，先过白名单 + 落盘内校验
        let dir = try skillDirectory(skill.id)
        // 清单 id 必须与目录 id 一致
        guard skill.id == dir.lastPathComponent || dir.lastPathComponent.hasPrefix("__builtin_") else {
            throw NSError(domain: "Skill", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "技能清单 id(\(skill.id.prefix(40))) 与目录 id(\(dir.lastPathComponent.prefix(40))) 不一致，已拒绝保存"
            ])
        }

        var updatedSkill = skill
        updatedSkill.updatedAt = Date()

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestData = try JSONEncoder().encode(updatedSkill)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)

        // 移除旧实例并重新加载
        skills.removeAll { $0.id == skill.id }
        if let loaded = loadSkill(at: dir) {
            skills.append(loaded)
            skills.sort { $0.manifest.name < $1.manifest.name }
        }
    }

    /// 启用/禁用技能
    func setEnabled(_ skill: InstalledSkill, enabled: Bool) {
        guard let idx = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        var updatedManifest = skills[idx].manifest
        updatedManifest.isEnabled = enabled
        updatedManifest.updatedAt = Date()
        do {
            try save(updatedManifest)
        } catch {
            print("[skill] 启用/禁用失败: \(error)")
        }
    }

    /// 删除技能
    func remove(_ skill: InstalledSkill) {
        // 内置技能只能禁用，不能删除
        if skill.isBuiltIn {
            setEnabled(skill, enabled: false)
            return
        }
        // 确认目录在 Skills 之内
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
    }

    /// 复制技能（另存为）
    func duplicate(_ skill: InstalledSkill, newName: String? = nil) throws {
        var newManifest = skill.manifest
        newManifest.id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description
        newManifest.name = newName ?? "\(skill.manifest.name) 副本"
        newManifest.version = "1.0.0"
        newManifest.isBuiltIn = false
        newManifest.createdAt = Date()
        newManifest.updatedAt = Date()
        newManifest.useCount = 0
        newManifest.lastUsedAt = nil
        try save(newManifest)
    }

    // MARK: - 导入/导出

    /// 导入 .lumenaiskill 文件
    func importBundle(data: Data) throws -> String? {
        let bundle = try JSONDecoder().decode(SkillBundle.self, from: data)
        var manifest = bundle.manifest
        manifest.isBuiltIn = false
        manifest.id = Self.safeSkillID(manifest.id) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description
        try save(manifest)
        return nil // 无警告
    }

    /// 导出技能为 .lumenaiskill
    func exportBundle(_ skill: InstalledSkill) throws -> Data {
        let bundle = SkillBundle(manifest: skill.manifest)
        return try JSONEncoder().encode(bundle)
    }

    /// 导入 SKILL.md 文件（通用技能格式）
    func importSkillMarkdown(data: Data) throws {
        guard let markdown = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "Skill", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "无法读取文件内容"
            ])
        }
        var manifest = try importFromMarkdown(markdown)
        // 确保 ID 清洗
        manifest.id = Self.safeSkillID(manifest.id) ?? UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24).description
        try save(manifest)
    }

    // MARK: - 使用统计

    func recordUse(_ skill: InstalledSkill) {
        guard let idx = skills.firstIndex(where: { $0.id == skill.id }) else { return }
        var updated = skills[idx].manifest
        updated.useCount += 1
        updated.lastUsedAt = Date()
        do {
            try save(updated)
        } catch {
            print("[skill] 记录使用失败: \(error)")
        }
    }

    // MARK: - 远程更新（应用内更新技能）

    /// 拉取远程索引，返回可安装/可更新列表
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
            let index = try JSONDecoder().decode(SkillIndex.self, from: data)
            remoteIndex = index.skills
            lastCheckError = nil
        } catch {
            lastCheckError = "检查更新失败: \(error.localizedDescription)"
        }
    }

    /// 获取可更新/可安装状态
    func updateStates() -> [SkillUpdate] {
        var states: [SkillUpdate] = []
        for entry in remoteIndex {
            let installed = skills.first { $0.id == entry.id }
            states.append(SkillUpdate(
                entry: entry,
                installedVersion: installed?.manifest.version
            ))
        }
        return states
    }

    /// 灰度判定
    func isGraySkill(_ entry: SkillIndexEntry) -> Bool {
        guard let gray = entry.gray else { return false }
        let bucket = UpdatePolicy.deviceBucket()
        return bucket < gray.percent
    }

    /// 安装或更新技能
    func installOrUpdate(_ entry: SkillIndexEntry) async -> String? {
        // 1. 校验 sha256
        if let expected = Self.declaredDigest(entry.sha256) {
            // 下载 manifest.json 校验
            guard let manifestURL = URL(string: entry.files.manifest) else {
                return "无效的清单下载地址"
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: manifestURL)
                if !Self.digestMatches(data, expected: expected) {
                    return "清单完整性校验失败（sha256 不匹配），已拒绝安装"
                }
            } catch {
                return "下载清单失败: \(error.localizedDescription)"
            }
        } else {
            // 没有 sha256 拒绝安装
            return "索引缺少 sha256，已拒绝安装（安全策略：fail-closed）"
        }

        // 2. 下载完整清单
        guard let manifestURL = URL(string: entry.files.manifest) else {
            return "无效的清单下载地址"
        }
        let manifestData: Data
        do {
            let (data, _) = try await URLSession.shared.data(from: manifestURL)
            manifestData = data
        } catch {
            return "下载清单失败: \(error.localizedDescription)"
        }

        let manifest: SkillManifest
        do {
            manifest = try JSONDecoder().decode(SkillManifest.self, from: manifestData)
        } catch {
            return "清单解析失败: \(error.localizedDescription)"
        }

        // 3. id 一致性
        guard manifest.id == entry.id else {
            return "清单 id 与索引不一致，已拒绝安装"
        }

        // 4. 安装
        do {
            try install(entry: entry, manifest: manifest, manifestData: manifestData)
        } catch {
            return "安装失败: \(error.localizedDescription)"
        }
        return nil
    }

    private func install(entry: SkillIndexEntry, manifest: SkillManifest, manifestData: Data) throws {
        let dir = try skillDirectory(entry.id)
        guard manifest.id == entry.id else {
            throw NSError(domain: "Skill", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "技能清单 id 与索引 id 不一致"
            ])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)

        skills.removeAll { $0.id == entry.id }
        if let loaded = loadSkill(at: dir) {
            skills.append(loaded)
            skills.sort { $0.manifest.name < $1.manifest.name }
        }
    }

    // MARK: - Agent 集成（技能可作为快捷方式注入对话）

    /// 获取所有启用的技能清单（用于在聊天界面显示快捷入口）
    func enabledSkills() -> [SkillManifest] {
        skills.filter { $0.isEnabled }.map { $0.manifest }
    }

    /// 根据 id 获取技能
    func skill(by id: String) -> SkillManifest? {
        skills.first { $0.id == id }?.manifest
    }

    /// 搜索技能
    func search(query: String) -> [SkillManifest] {
        let q = query.lowercased()
        return skills.filter { skill in
            skill.manifest.name.lowercased().contains(q) ||
            skill.manifest.description.lowercased().contains(q) ||
            skill.manifest.tags.contains { $0.lowercased().contains(q) }
        }.map { $0.manifest }
    }
}

// MARK: - 远程索引模型

struct SkillIndex: Codable, Sendable {
    var skills: [SkillIndexEntry]
}