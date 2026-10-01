import Foundation
import CryptoKit

/// 模块（JS 插件）管理器：
/// - 模块存放于 Documents/Modules/<id>/（manifest.json + tools.js），独立版本、独立更新
/// - 基础包（IPA）不动；模块更新在 App 内完成（下载 → 替换文件 → 重新加载）
/// - 远程索引：GitHub 仓库 modules/index.json（可随时指向其他源）
///
/// 安全边界（本文件是"模块能不能装进来"的唯一入口，三处全部是必须项）：
/// 1. **id 白名单**（safeModuleID）：目录用 id 拼出来，而 id 来自远端 index.json
///    / 本地 .localaimod 的 manifest，从前没有任何格式校验 —— id = "../../Documents/x"
///    就能把 tools.js 写到 Modules 之外（配合 Agent 的文件读取就是任意落盘 + 任意执行）。
/// 2. **sha256 完整性**：插件是"远端代码 + 本机权限"（网络 + 存储桥），
///    从前唯一的检查是 minAppVersion 版本比较，等于远端仓库的任意 JS 都会被静默安装。
/// 3. **落盘前归一化兜底**：id 过了白名单之后仍再校验一次最终路径必须落在
///    modulesDir 之内（见 moduleDirectory），防止将来有人绕过 safeModuleID 直接拼路径。
@MainActor
final class PluginManager: ObservableObject {

    static let shared = PluginManager()

    /// 已安装模块（含加载好的 JS 引擎）
    struct InstalledModule: Identifiable, Sendable {
        let manifest: PluginManifest
        let directory: URL
        let engine: JSPluginEngine
        var id: String { manifest.id }
        var toolCount: Int { engine.tools.count }
        /// 该模块是否因"调用超时无法终止"被永久摘除（③）。UI 可据此显示「已停用」徽标，
        /// 而不是继续显示成一堆可用工具（工具目录已经不再暴露它）。
        var isDisabled: Bool { engine.isDisabled }
        var disabledReason: String? { engine.disabledReason }
    }

    @Published private(set) var modules: [InstalledModule] = []
    @Published private(set) var remoteIndex: [ModuleIndexEntry] = []
    @Published private(set) var isChecking = false
    @Published var lastCheckError: String?

    /// 上一次安装/更新留下的**非致命提示**（安装成功了，但有话要说）。
    ///
    /// 为什么必须是独立的通道，而不是塞进 `installOrUpdate` 的返回值：
    /// 那个返回值的语义已经被调用方定死为「非 nil = 失败」（`PluginsView` 拿它去弹
    /// 「导入失败」alert）。把"这次装的东西没经过校验"这种**成功但有保留**的信息塞进去，
    /// 用户会看到一条红字报错说安装失败，转头却发现模块已经装好了 —— 比不提示更糟。
    ///
    /// 这个字段存在的直接原因是一个被编译器优化掉的 bug：`unverifiedWarning` 原来只是个
    /// 局部变量，赋值后再没被读过（函数结尾 `return conflictWarning(...)`），
    /// 于是 -O 下那整段字符串被当作死代码消除。二进制里连
    /// 「该模块未提供 sha256 校验值…」这句都不存在 —— 也就是说"兼容优先"这个决定
    /// 在**用户可见层面从未生效过**：无摘要的模块确实放行了（这点生效了），
    /// 但"未经完整性校验"这句提醒一次都没出现过。赋值即丢弃的变量骗过了代码审查，
    /// 只有去二进制里找那句字符串才看得出来。
    @Published private(set) var installNotice: String?
    /// 可更新模块数量（服务页角标）
    var updatableCount: Int {
        updateStates().filter(\.hasUpdate).count
    }

    /// 启动静默检查（1 天节流）
    private let lastCheckKey = "plugin_check_ts"
    func checkForUpdatesIfNeeded() async {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= 86400 else { return }
        await checkForUpdates()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
    }

    private let modulesDir: URL
    /// 模块索引地址（GitHub raw；可换成自己的静态站点）
    private let indexURL = "https://raw.githubusercontent.com/nmn999999999/LumenAI/main/modules/index.json"

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        modulesDir = docs.appendingPathComponent("Modules", isDirectory: true)
        try? FileManager.default.createDirectory(at: modulesDir, withIntermediateDirectories: true)
        loadAll()
    }

    // MARK: - id 清洗 / 完整性校验（安全工具，全部路径都必须过这里）

    /// 只允许 [A-Za-z0-9._-]，且拒绝 "."、".."、以点开头、长度 0 或 >64 的 id。
    /// 返回 nil 表示非法。
    ///
    /// 为什么需要它：id 来自远端 index.json 和 .localaimod，**都不是我们写的数据**，
    /// 却被直接 appendingPathComponent 拼成落盘目录。以前 `id = "../../Documents/agent_notes"`
    /// 就能把 manifest.json / tools.js 写到 Modules 之外 —— 而写进去的 tools.js
    /// 下次会被当代码执行。故意不做 trim：允许首尾空白会产生"看着合法、落盘名带空格、
    /// 与 manifest.id 不一致"的目录，宁可拒绝。
    static func safeModuleID(_ raw: String) -> String? {
        guard !raw.isEmpty, raw.count <= 64 else { return nil }
        guard raw != ".", raw != "..", !raw.hasPrefix(".") else { return nil }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        guard raw.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return raw
    }

    /// 非法 id 的统一错误（带原文，方便用户/作者定位是哪个模块）
    static func invalidIDError(_ raw: String) -> NSError {
        NSError(domain: "Plugin", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "模块 id 非法: \(raw.prefix(60))（只允许字母数字 . _ -，不能以点开头）"
        ])
    }

    /// 由 id 得到模块目录，两个检查缺一不可：
    /// 1. safeModuleID 白名单；
    /// 2. **第二道防线**：把拼出来的路径 standardizedFileURL / 解析软链之后再确认它落在
    ///    modulesDir 之内。白名单是逻辑判断，将来若有人改错了白名单、或者 Modules 下被人
    ///    放了指向外部的符号链接，这一层还能兜住（例如 "a" 是 -> /tmp 的软链）。
    private func moduleDirectory(_ rawID: String) throws -> URL {
        guard let id = Self.safeModuleID(rawID) else { throw Self.invalidIDError(rawID) }
        let dir = modulesDir.appendingPathComponent(id, isDirectory: true)
        let base = modulesDir.standardizedFileURL.resolvingSymlinksInPath().path
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

    /// 期望值归一化：作者从 `shasum -a 256` 输出里粘过来常带大写/首尾空白/前缀，
    /// 因为我们卡的是安全项，不能因为格式差异把正常模块判死（但内容必须一致）。
    static func normalizeDigest(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.hasPrefix("sha256:") { s = String(s.dropFirst("sha256:".count)) }
        return s
    }

    /// 内容与声明值是否一致
    static func digestMatches(_ data: Data, expected: String) -> Bool {
        Self.sha256Hex(data) == Self.normalizeDigest(expected)
    }

    /// 只有"索引/清单真的给了值"才算声明了校验值（空串/空白视为没给）
    private static func declaredDigest(_ raw: String?) -> String? {
        guard let raw, !Self.normalizeDigest(raw).isEmpty else { return nil }
        return raw
    }

    // MARK: - 本地加载

    private func loadAll() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: modulesDir, includingPropertiesForKeys: nil) else { return }
        var loaded: [InstalledModule] = []
        for dir in dirs {
            guard dir.hasDirectoryPath else { continue }
            if let module = loadModule(at: dir) {
                loaded.append(module)
            }
        }
        modules = loaded.sorted { $0.manifest.name < $1.manifest.name }
    }

    private func loadModule(at dir: URL) -> InstalledModule? {
        let fm = FileManager.default
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let jsURL = dir.appendingPathComponent("tools.js")
        guard let manifestData = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData),
              let jsSource = try? String(contentsOf: jsURL, encoding: .utf8)
        else { return nil }
        // 磁盘上的东西也要过一遍 id 校验：目录名与 manifest.id 必须都是合法 id 且一致。
        // 只靠安装口把关不够 —— 老版本装进来的、或者从外面拷进容器/备份恢复的目录，
        // 里面的 manifest.id 可能是 "../x"，它会一路带进 modules 数组（导出文件名、
        // 引擎队列标签、未来的路径拼接都会用它）。不一致的目录宁可不加载。
        guard let dirID = Self.safeModuleID(dir.lastPathComponent),
              Self.safeModuleID(manifest.id) == dirID
        else {
            print("[plugin] 跳过非法模块目录: \(dir.lastPathComponent) (manifest.id=\(manifest.id))")
            return nil
        }
        let storageFile = dir.appendingPathComponent("storage.json")
        guard let engine = JSPluginEngine(manifest: manifest, jsSource: jsSource, storageFile: storageFile) else { return nil }
        return InstalledModule(manifest: manifest, directory: dir, engine: engine)
    }

    // MARK: - 增删

    /// 安装/更新模块：写入 manifest.json + tools.js 后重新加载
    func install(entry: ModuleIndexEntry, manifest: PluginManifest, jsSource: String) throws {
        // ① 唯一拼路径的地方，先过白名单 + 落盘内校验；非法即抛错给用户看，不静默失败
        let dir = try moduleDirectory(entry.id)
        // 清单 id 与索引 id 必须完全一致：否则会出现"目录是合法 id、清单里写着穿越 id"
        // 的模块，loadModule 之后这个 id 会进入 modules 数组（导出文件名等都要用它）。
        guard manifest.id == entry.id else {
            throw NSError(domain: "Plugin", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "模块清单 id(\(manifest.id.prefix(40))) 与索引 id(\(entry.id.prefix(40))) 不一致，已拒绝安装"
            ])
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: dir.appendingPathComponent("manifest.json"), options: .atomic)
        try jsSource.data(using: .utf8)?.write(to: dir.appendingPathComponent("tools.js"), options: .atomic)
        // 移除旧实例并重新加载
        modules.removeAll { $0.id == entry.id }
        if let module = loadModule(at: dir) {
            modules.append(module)
            modules.sort { $0.manifest.name < $1.manifest.name }
        }
    }

    /// 读取模块存储（远程 UI 用）
    func storageValue(module: InstalledModule, key: String) -> String? {
        module.engine.storageGet(key)
    }

    /// 写入模块存储（远程 UI 用）
    func setStorageValue(module: InstalledModule, key: String, value: String) {
        module.engine.storageSet(key, value)
    }

    /// 清空模块存储（远程 UI 的 reset 动作）
    func resetStorage(module: InstalledModule) {
        let dir = module.directory
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("storage.json"))
        if let reloaded = loadModule(at: dir) {
            if let idx = modules.firstIndex(where: { $0.id == module.id }) {
                modules[idx] = reloaded
            }
        }
    }

    func remove(_ module: InstalledModule) {
        // 删除是破坏性操作，且它用的是 module.directory：先确认这个目录确实在
        // Modules 之内（万一某天有人给 InstalledModule 传了外部路径，
        // 这里不会跟着 rm -rf 掉用户的其他数据），id 也必须合法。
        guard Self.safeModuleID(module.id) != nil else {
            print("[plugin] 拒绝删除 id 非法的模块: \(module.id.prefix(60))")
            return
        }
        let base = modulesDir.standardizedFileURL.resolvingSymlinksInPath().path
        let target = module.directory.standardizedFileURL.resolvingSymlinksInPath().path
        guard target.hasPrefix(base + "/") else {
            print("[plugin] 拒绝删除 Modules 之外的路径: \(target)")
            return
        }
        try? FileManager.default.removeItem(at: module.directory)
        modules.removeAll { $0.id == module.id }
    }

    // MARK: - Agent 集成

    /// 全部已安装模块的工具定义（注入 Agent 工具目录）
    func installedToolDefinitions() -> [AgentToolDefinition] {
        // ③ 因调用超时被永久摘除的模块不再进工具目录：否则模型会反复调用它，
        //    每一次都在旧队列上把那个停不下来的 JS 又跑一遍（每次卡死一个核）。
        modules.filter { !$0.engine.isDisabled }.flatMap { $0.engine.toolDefinitions() }
    }

    func hasTool(named name: String) -> Bool {
        modules.contains { !$0.engine.isDisabled && $0.engine.tools.contains { $0.name == name } }
    }

    func callTool(name: String, argumentsJSON: String) async -> String {
        for module in modules {
            if let def = module.engine.tools.first(where: { $0.name == name }) {
                // 被摘除的模块即使被叫到名字也不执行（引擎内部也有同样的拒绝，
                // 这里是为了让用户/模型看到原因，而不是一句"未知工具"）
                if module.engine.isDisabled {
                    return "模块已停用（\(module.manifest.name)）: \(module.engine.disabledReason ?? "调用超时")"
                }
                return await module.engine.call(name: def.name, argumentsJSON: argumentsJSON)
            }
        }
        return "错误: 未知工具: \(name)"
    }

    // MARK: - 远程更新（应用内更新模块）

    /// 拉取远程索引，返回可安装/可更新列表
    func checkForUpdates() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        guard let url = URL(string: indexURL) else {
            lastCheckError = "无效的模块索引地址"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("LumenAI-iOS/plugin", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                lastCheckError = "模块索引响应异常 (HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1))"
                return
            }
            let index = try JSONDecoder().decode(ModuleIndex.self, from: data)
            remoteIndex = index.modules
            lastCheckError = nil
        } catch {
            lastCheckError = "检查失败: \(error.localizedDescription.prefix(60))"
        }
    }

    /// 安装或更新远程索引里的模块
    func installOrUpdate(_ entry: ModuleIndexEntry) async -> String? {
        // ① entry.id 来自远端 index.json，拼路径之前先过白名单。
        //    直接 return 错误串（而不是 throw）是因为这个字符串会原样进 UI 的 alert，
        //    不能被下面 catch 里的 60 字截断吃掉关键信息。
        guard Self.safeModuleID(entry.id) != nil else {
            return "模块 id 非法: \(entry.id.prefix(60))（只允许字母数字 . _ -，不能以点开头），已拒绝安装"
        }
        guard let manifestURL = URL(string: entry.files.manifest),
              let toolsURL = URL(string: entry.files.tools)
        else { return "无效的模块地址" }
        // 每次重新安装都先清空上一条提示：不清的话，上一次"未经验证"的警告会挂到
        // 下一次（这次校验通过了）的安装上，用户会以为刚装的这个也有问题。
        installNotice = nil
        do {
            let (manifestData, mResp) = try await URLSession.shared.data(from: manifestURL)
            guard (mResp as? HTTPURLResponse)?.statusCode == 200 else { return "清单下载失败" }

            // ② 清单完整性：索引给了 manifestSha256 就必须对得上。
            //    清单决定 permissions（是否联网）与远程设置界面，被改同样是提权。
            if let expectedManifest = Self.declaredDigest(entry.manifestSha256) {
                guard Self.digestMatches(manifestData, expected: expectedManifest) else {
                    return "模块校验失败: manifest.json 的 sha256 不匹配"
                }
            }

            let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData)

            // 清单 id 必须与索引 id 一致（防止"目录名合法、清单里写穿越 id"）
            guard manifest.id == entry.id else {
                return "模块清单 id 与索引 id 不一致，已拒绝安装"
            }

            // 版本兼容检查：App 版本低于模块要求 → 拒绝安装
            let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
            if let required = manifest.minAppVersion, !required.isEmpty,
               UpdateCheckerService.compare(UpdateCheckerService.stripV(required), appVersion) > 0 {
                return "需要升级 App 到 v\(required) 才能安装此模块"
            }
            let (jsData, tResp) = try await URLSession.shared.data(from: toolsURL)
            guard (tResp as? HTTPURLResponse)?.statusCode == 200,
                  let jsSource = String(data: jsData, encoding: .utf8)
            else { return "脚本下载失败" }

            // ② tools.js 完整性校验 —— 必须在写盘之前（下面 try install 就是唯一落盘点）。
            // 取舍说明（**兼容优先**，是产品决定后选的）：
            // - 原来的流程只有 minAppVersion 比较，于是"仓库当前是谁的"= "谁的代码能在这台
            //   手机上跑"，而且一装完就拿到 nativeFetchAsync（联网）与存储桥。
            // - 现在的策略是**三档**，而不是一刀切：
            //     有摘要 → 必须匹配，不匹配一律拒绝（写盘前）
            //     无摘要 → **放行**，但打一条明确的日志，并在返回值里附上提示，
            //              让用户知道"这次装的是未经验证的代码"
            // - 为什么改回兼容优先（曾实现过 fail-closed）：仓库 modules/index.json 里现有
            //   模块都没写 sha256，fail-closed 会让**所有模块都装不上** —— 这是用户可见的
            //   功能中断，代价大于收益。安全性没有被放弃，只是从"默认拒绝"变成"有则必验"。
            // - **如实标注降级**：无摘要时这套校验对"控制了 tools.js 主机的人"没有防护力。
            //   真正的解法是让 index.json 带上 sha256（强锚点，见下），那属于仓库侧的工作。
            //
            // 锚点强弱（写清楚是因为它决定了"防住谁"）：
            // * index.json 的 sha256 = **强锚点**：它在另一条通道上，控制了 tools.js 主机的人
            //   改不动它 —— 这才是供应链校验真正想防的对手。
            // * 清单里的 toolsSha256 = **弱锚点**：清单和 tools.js 常常同源，能改脚本的人
            //   顺手就能把清单里的哈希一起改成新值，所以它只挡传输损坏/单文件被替换，
            //   挡不住控制了那个主机的人。保留它是为了不把作者逼到"没补索引就完全装不上"，
            //   但走弱锚点时打一行日志，排查/审计时能看出这次装的是哪一种。
            let indexDigest = Self.declaredDigest(entry.sha256)
            let manifestDigest = Self.declaredDigest(manifest.toolsSha256)
            var unverifiedWarning: String?
            if let expectedTools = indexDigest ?? manifestDigest {
                // 有摘要：必须匹配，不匹配就中止（且此时还没写到磁盘）
                guard Self.digestMatches(jsData, expected: expectedTools) else {
                    return "模块校验失败: tools.js 的 sha256 不匹配"
                }
                if indexDigest == nil {
                    print("[plugin] \(entry.id): 本次校验用的是清单自述的 toolsSha256（弱锚点，清单与脚本同源）—— 建议作者在 index.json 补 sha256")
                }
            } else {
                // 无摘要：兼容优先，放行但**不静默** —— 控制台留痕 + 返回提示带给用户。
                // 这样"装不上"不会发生，但"这次装的东西没人验过"这件事是可见的。
                unverifiedWarning = "该模块未提供 sha256 校验值，已按兼容策略安装（内容未经完整性校验）。建议模块作者在 index.json 里补上 sha256。"
                print("[plugin] \(entry.id): ⚠ 索引与清单都没有 sha256，按兼容策略放行安装（未校验完整性）")
            }

            try install(entry: entry, manifest: manifest, jsSource: jsSource)
            // 安装成功（返回 nil = 无错误），但可能带着两条"有保留"的信息：
            //   ① 没有 sha256 → 这次装的是未经验证的代码；
            //   ② 工具名与内置/MCP 冲突 → 插件里同名的那个不会被调用。
            // 两条都走 installNotice（提示），不走返回值（错误）—— 理由见该字段的注释。
            let warning = conflictWarning(for: manifest.id)
            let notices = [unverifiedWarning, warning].compactMap { $0 }
            installNotice = notices.isEmpty ? nil : notices.joined(separator: "\n")
            return nil
        } catch {
            return "安装失败: \(error.localizedDescription.prefix(60))"
        }
    }

    /// 从本地 .localaimod 导入并安装（返回警告信息；nil = 成功无警告）
    func importBundle(data: Data) throws -> String? {
        let (manifest, tools) = try parseImport(data: data)

        // ① 本地包也要清洗 id：.localaimod 是"别人发给我、我手动选进来"的文件，
        //    里面同样可能写着 "../../Documents/agent_notes"。
        guard Self.safeModuleID(manifest.id) != nil else {
            throw Self.invalidIDError(manifest.id)
        }

        // ② 本地包只有一个文件，锚点只能是清单自述的 toolsSha256：
        //    给了就强校验（能挡住传坏/被换），没给则放行 —— 这里与远端安装的
        //    fail-closed 不同，理由是语义不同：本地导入是**用户自己挑的文件**，
        //    等于用户自己的一次信任决策（系统不给应用任何"用户面前的替代方案"）；
        //    而远端安装是应用主动去仓库拉代码，必须由我们负责验证。
        if let expectedTools = Self.declaredDigest(manifest.toolsSha256) {
            guard Self.digestMatches(Data(tools.utf8), expected: expectedTools) else {
                throw NSError(domain: "Plugin", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "模块校验失败: tools.js 的 sha256 不匹配"
                ])
            }
        }

        let entry = ModuleIndexEntry(
            id: manifest.id,
            name: manifest.name,
            version: manifest.version,
            description: manifest.description,
            author: manifest.author,
            minAppVersion: manifest.minAppVersion,
            permissions: manifest.permissions,
            files: .init(manifest: "", tools: "")
        )
        try install(entry: entry, manifest: manifest, jsSource: tools)
        return conflictWarning(for: manifest.id)
    }

    /// 工具名冲突检查：插件工具与内置/MCP 同名 → 内置优先（插件同名的不会被调用）
    private func conflictWarning(for moduleID: String) -> String? {
        guard let module = modules.first(where: { $0.id == moduleID }) else { return nil }
        let builtinNames = Set(BuiltInTools.allTools.map(\.name))
        let mcpNames = Set(MCPService.shared.toolDefinitions.map(\.name))
        let conflicts = module.engine.tools
            .map(\.name)
            .filter { builtinNames.contains($0) || mcpNames.contains($0) }
        guard !conflicts.isEmpty else { return nil }
        return "⚠️ 工具名与已有工具冲突（内置优先）: \(conflicts.joined(separator: ", "))"
    }

    // MARK: - 本地导入 / 导出（.localaimod = LZ4 压缩的 {"manifest":..., "tools":"..."}）

    /// 导出已安装模块为 .localaimod 文件（可分享给他人导入）
    func exportModule(_ module: InstalledModule) -> URL? {
        let dir = module.directory
        guard let manifestData = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData),
              let jsSource = try? String(contentsOf: dir.appendingPathComponent("tools.js"), encoding: .utf8)
        else { return nil }
        // id 也进了文件名（临时目录里的 "\(id)-\(version).localaimod"）：
        // id = "../../x" 会让临时文件落到 temporaryDirectory 之外，所以同样过白名单。
        guard Self.safeModuleID(module.manifest.id) != nil else {
            print("[plugin] 拒绝导出 id 非法的模块: \(module.manifest.id.prefix(60))")
            return nil
        }
        let bundle: [String: Any] = ["manifest": manifest, "tools": jsSource]
        guard let json = try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted]) else { return nil }
        let compressed = LZ4.compress(json)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(module.manifest.id)-\(module.manifest.version).localaimod")
        try? compressed.write(to: file)
        return file
    }

    /// 解析 .localaimod 数据 → (manifest, tools)
    /// 格式：LZ4 压缩的 {"manifest": {...}, "tools": "..."}；兼容未压缩的明文 JSON。
    func parseImport(data: Data) throws -> (PluginManifest, String) {
        let decompressed: Data
        if let d = LZ4.decompress(data) {
            decompressed = d
        } else {
            decompressed = data   // 明文 JSON 兼容
        }
        guard let json = (try? JSONSerialization.jsonObject(with: decompressed)) as? [String: Any],
              let manifestData = try? JSONSerialization.data(withJSONObject: json["manifest"] as Any),
              let manifest = try? JSONDecoder().decode(PluginManifest.self, from: manifestData),
              let tools = json["tools"] as? String
        else {
            throw NSError(domain: "Plugin", code: 1, userInfo: [NSLocalizedDescriptionKey: "无效的 .localaimod 文件"])
        }
        return (manifest, tools)
    }

    // MARK: - 状态查询

    /// 可安装/可更新列表（按远程索引；灰度模块只对命中灰度的设备显示）
    func updateStates() -> [ModuleUpdate] {
        let optIn = UserDefaults.standard.bool(forKey: UpdateCheckerService.grayOptInKey)
        return remoteIndex
            .filter { entry in
                // 灰度模块：非灰度设备隐藏（已安装的保留，不自动卸载）
                guard let gray = entry.gray else { return true }
                return UpdatePolicy.inGray(percent: gray.percent, optIn: optIn)
            }
            .map { entry in
                ModuleUpdate(entry: entry, installedVersion: modules.first { $0.id == entry.id }?.manifest.version)
            }
    }

    /// 模块是否处于灰度中（UI 徽标）
    func isGrayModule(_ entry: ModuleIndexEntry) -> Bool {
        entry.gray != nil
    }
}
