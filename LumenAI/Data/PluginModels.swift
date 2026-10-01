import Foundation

// MARK: - JS 插件模型（manifest.json 结构）
//
// ⚠️ 安全前提（写在这里是因为模型层是"谁能进得来"的第一道口）：
// 插件 = **远端代码 + 本机权限**。index.json / manifest.json 都从远端仓库拉，
// 装进来之后这段 JS 立刻能用 nativeFetchAsync（联网）和 storage 桥读写本机文件。
// 也就是说"索引被人改一行"等价于"我们的 App 执行别人的任意代码"。
// 因此：① id 必须能被白名单校验（否则可路径穿越写出 Modules 之外）；
// ② 内容完整性（sha256）是**必需项**而不是可选项 —— 没有校验值的模块宁可不装（fail-closed）；
// ③ 插件返回值属于外部数据，回灌模型时必须带"不可信"边界标记。
// 这三条的落点分别在 PluginManager.safeModuleID / installOrUpdate / JSPluginEngine.describe。

/// 插件清单：模块元信息（每个模块一个文件夹，位于 Documents/Modules/<id>/）
struct PluginManifest: Codable, Sendable {
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    /// 最低 App 版本（如 "0.3.36"）；低于则提示升级 App
    var minAppVersion: String?
    /// 声明的权限：["network"]（联网，需授权）/ ["storage"]（模块本地存储）
    var permissions: [String]
    /// 远程设置界面（不换底包即可改变配置界面；JSON 声明式，App 渲染）
    var settingsUI: [RemoteUIGroup]?
    /// 本模块 tools.js 的 SHA256（十六进制，可带大小写与空白）。
    /// 本地导入（.localaimod）时用它做完整性校验：包只有一个文件，索引里的
    /// sha256 锚不住它，只能靠清单自述。注意它的保护力边界 —— 清单和脚本
    /// 一起被改的话这个值也会被一起改，所以对**远程安装**真正的锚点是
    /// index.json 里的 sha256（那才是安装者要校验的目标），清单里的值只用于
    /// 本地包"有没有被传坏/被换过"的检查。
    var toolsSha256: String?

    init(
        id: String,
        name: String,
        version: String,
        description: String,
        author: String? = nil,
        minAppVersion: String? = nil,
        permissions: [String] = [],
        settingsUI: [RemoteUIGroup]? = nil,
        toolsSha256: String? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.minAppVersion = minAppVersion
        self.permissions = permissions
        self.settingsUI = settingsUI
        self.toolsSha256 = toolsSha256
    }

    // 旧存档/旧清单没有 permissions → 默认 []
    enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, minAppVersion, permissions, settingsUI, toolsSha256
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        description = try c.decode(String.self, forKey: .description)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions) ?? []
        settingsUI = try c.decodeIfPresent([RemoteUIGroup].self, forKey: .settingsUI)
        // 老清单没有这个字段，必须 decodeIfPresent，否则已装模块/老 .localaimod 全部解析失败
        toolsSha256 = try c.decodeIfPresent(String.self, forKey: .toolsSha256)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(version, forKey: .version)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(author, forKey: .author)
        try c.encodeIfPresent(minAppVersion, forKey: .minAppVersion)
        try c.encode(permissions, forKey: .permissions)
        try c.encodeIfPresent(settingsUI, forKey: .settingsUI)
        try c.encodeIfPresent(toolsSha256, forKey: .toolsSha256)
    }
}

/// 插件工具定义（由 tools.js 里 registerTool() 注册，App 读取后转成 AgentToolDefinition）
struct PluginToolDef: Codable, Sendable {
    var name: String
    var description: String
    var parameters: [String: PluginParam]

    init(name: String, description: String, parameters: [String: PluginParam] = [:]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

struct PluginParam: Codable, Sendable {
    var type: String
    var description: String

    init(type: String = "string", description: String = "") {
        self.type = type
        self.description = description
    }
}

/// 远程模块索引条目（modules/index.json）
struct ModuleIndexEntry: Codable, Sendable, Identifiable {
    var id: String
    var name: String
    var version: String
    var description: String
    var author: String?
    var minAppVersion: String?
    var permissions: [String]?
    /// 模块灰度策略（可选）：命中灰度的设备才在市场看到该模块
    var gray: ModuleGrayPolicy?
    /// tools.js 的 SHA256（十六进制；可选是为了让**老索引仍能解析**）。
    /// 安装侧对它是 fail-closed 的：有值必须匹配，没有值直接拒绝安装
    /// （见 PluginManager.installOrUpdate —— 远端仓库的任意 JS 一装进来就有
    /// nativeFetchAsync 联网能力和存储桥，没有完整性校验就等于把这台机器
    /// 交给仓库的当前持有者）。
    var sha256: String?
    /// manifest.json 自身的 SHA256（可选）。索引里给得出就给，给了即强校验：
    /// 清单决定权限声明（permissions）与远程设置界面，被改一样是提权。
    var manifestSha256: String?
    /// 各文件的下载地址
    var files: ModuleFiles

    struct ModuleFiles: Codable, Sendable {
        var manifest: String
        var tools: String
    }

    /// 显式写出成员初始化器：下面自定义了 init(from:)，编译器不会再合成这个
    /// 逐成员初始化器，而 PluginManager.importBundle 在用（保持原有实参顺序与默认值）。
    init(
        id: String,
        name: String,
        version: String,
        description: String,
        author: String? = nil,
        minAppVersion: String? = nil,
        permissions: [String]? = nil,
        gray: ModuleGrayPolicy? = nil,
        sha256: String? = nil,
        manifestSha256: String? = nil,
        files: ModuleFiles
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.minAppVersion = minAppVersion
        self.permissions = permissions
        self.gray = gray
        self.sha256 = sha256
        self.manifestSha256 = manifestSha256
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case id, name, version, description, author, minAppVersion, permissions, gray, sha256, manifestSha256, files
    }

    /// 新字段一律 decodeIfPresent：线上老索引里没有 sha256/manifestSha256，
    /// 用 decode 会让整个索引解析失败 → 用户会看到"检查更新失败"而不是新模块。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        version = try c.decode(String.self, forKey: .version)
        description = try c.decode(String.self, forKey: .description)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
        permissions = try c.decodeIfPresent([String].self, forKey: .permissions)
        gray = try c.decodeIfPresent(ModuleGrayPolicy.self, forKey: .gray)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        manifestSha256 = try c.decodeIfPresent(String.self, forKey: .manifestSha256)
        files = try c.decode(ModuleFiles.self, forKey: .files)
    }
}

struct ModuleIndex: Codable, Sendable {
    var modules: [ModuleIndexEntry]
}

/// 模块更新状态（UI 用）
struct ModuleUpdate: Identifiable, Sendable {
    let entry: ModuleIndexEntry
    var id: String { entry.id }
    /// nil = 未安装；非 nil = 已安装版本
    let installedVersion: String?
    var hasUpdate: Bool { installedVersion != entry.version }
}
