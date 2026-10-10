import Foundation

/// 应用更新检查（滚动更新引导）
/// iOS 侧载应用无法自更新，这里做到侧载场景下的最优形态：
/// 自动检查 GitHub Release → 提示新版本与更新说明 → 一键跳转下载新 IPA（用户手动重装）。
@MainActor
final class UpdateCheckerService: ObservableObject {

    static let shared = UpdateCheckerService()

    @Published private(set) var latestTag: String?
    @Published private(set) var latestName: String?
    @Published private(set) var releaseNotes: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var downloadURL: URL?
    @Published private(set) var isChecking = false
    @Published private(set) var lastChecked = false
    /// 最近一次检查失败的原因（nil = 成功或尚未检查）。UI 用它区分「已是最新」与「检查失败」。
    @Published private(set) var lastError: String?
    /// 当前是否处于灰度通道（命中灰度 or 已开启参与灰度）
    @Published private(set) var isGray = false
    /// 灰度比例（有活跃灰度时显示）
    @Published private(set) var grayPercent: Int?

    /// 用户是否强制参与灰度（微信式内测开关）
    static let grayOptInKey = "update_gray_opt_in"

    private let repoAPI = "https://api.github.com/repos/nmn999999999/LumenAI/releases/latest"
    private let lastCheckKey = "update_last_check_ts"
    /// 自动检查最小间隔（秒）：1 天
    private let minInterval: TimeInterval = 86400

    /// 当前安装版本（来自 Info.plist MARKETING_VERSION）
    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 是否存在可更新的新版本
    var hasUpdate: Bool {
        guard let latestTag else { return false }
        return Self.compare(Self.stripV(latestTag), currentVersion) > 0
    }

    /// 启动静默检查：距上次成功检查 < 间隔则跳过（省流量）
    func checkIfNeeded() async {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date().timeIntervalSince1970 - last >= minInterval else { return }
        await check()
    }

    /// 执行检查（手动 / 自动）。失败时记录 lastError，UI 显示「检查失败」而非误导性的「已是最新」。
    /// 优先级：灰度索引 update/index.json（支持微信式灰度）→ 失败时回退 GitHub releases/latest。
    func check() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        defer { lastChecked = true }

        let optIn = UserDefaults.standard.bool(forKey: Self.grayOptInKey)

        // 1) 灰度索引
        if await checkGrayIndex(optIn: optIn) {
            lastError = nil
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
            return
        }

        // 2) 回退：GitHub releases/latest（无灰度能力）
        isGray = false
        grayPercent = nil
        guard let url = URL(string: repoAPI) else {
            lastError = "无效的更新地址"
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("LumenAI-iOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastError = "服务器响应异常 (HTTP \(code))"
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                lastError = "响应解析失败"
                return
            }

            latestTag = json["tag_name"] as? String
            latestName = json["name"] as? String
            releaseNotes = json["body"] as? String
            if let html = json["html_url"] as? String {
                releaseURL = URL(string: html)
            }
            downloadURL = nil
            if let assets = json["assets"] as? [[String: Any]] {
                downloadURL = Self.ipaAsset(from: assets)
            }
            lastError = nil   // 成功
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastCheckKey)
        } catch {
            lastError = "网络请求失败: \(error.localizedDescription.prefix(60))"
        }
    }

    /// 从灰度索引解析对当前设备生效的版本。返回是否成功（网络/解析均成功）。
    /// v0.3.44 修复：索引漏更新时稳定版会停滞（曾因索引停留在 0.3.41 导致 0.3.42/43 检测不到）。
    /// 稳定版解析后与 GitHub releases/latest 交叉取较大者自愈；灰度版只认索引（灰度版不进 Release）。
    private func checkGrayIndex(optIn: Bool) async -> Bool {
        guard let url = URL(string: UpdatePolicy.indexURL) else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("LumenAI-iOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return false
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            guard let index = try? decoder.decode(AppUpdateIndex.self, from: data) else {
                return false
            }
            let resolved = UpdatePolicy.resolveAppUpdate(index, optInGray: optIn)

            if resolved.isGray {
                // 灰度版：只用索引（灰度版不在 GitHub Release，天然隔离）
                isGray = true
                grayPercent = index.gray?.enabled == true ? index.gray?.percent : nil
                latestTag = resolved.version
                latestName = "\(resolved.version)（灰度）"
                releaseNotes = resolved.notes
                releaseURL = nil
                downloadURL = resolved.ipa
                return true
            }

            // 稳定版：与 GitHub releases/latest 交叉取较大者（索引漏更时自愈）
            isGray = false
            grayPercent = index.gray?.enabled == true ? index.gray?.percent : nil
            latestTag = resolved.version
            latestName = resolved.version
            releaseNotes = resolved.notes
            releaseURL = URL(string: "https://github.com/nmn999999999/LumenAI/releases/latest")
            downloadURL = resolved.ipa
            if let gh = await fetchGitHubLatest(),
               Self.compare(Self.stripV(gh.tag), resolved.version) > 0 {
                latestTag = gh.tag
                latestName = gh.tag
                releaseNotes = gh.notes
                releaseURL = gh.url
                downloadURL = gh.ipa
            }
            return true
        } catch {
            return false
        }
    }

    /// 抓取 GitHub releases/latest（供回退与稳定版交叉自愈）
    private func fetchGitHubLatest() async -> (tag: String, notes: String?, url: URL, ipa: URL?)? {
        guard let url = URL(string: repoAPI) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("LumenAI-iOS/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String
        else { return nil }
        let notes = json["body"] as? String
        let html = (json["html_url"] as? String).flatMap { URL(string: $0) }
        var ipa: URL?
        if let assets = json["assets"] as? [[String: Any]] {
            ipa = Self.ipaAsset(from: assets)
        }
        return (tag, notes, html ?? url, ipa)
    }

    /// 从 Release assets 里挑第一个 `.ipa`。
    static func ipaAsset(from assets: [[String: Any]]) -> URL? {
        for asset in assets {
            let name = (asset["name"] as? String) ?? ""
            guard name.lowercased().hasSuffix(".ipa"),
                  let browserURL = (asset["browser_download_url"] as? String).flatMap({ URL(string: $0) })
            else { continue }
            return browserURL
        }
        return nil
    }

    /// 去掉 tag 的 "v" 前缀
    static func stripV(_ tag: String) -> String {
        tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    /// 语义化版本比较：a > b → 1，a < b → -1，相等 → 0
    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y ? 1 : -1 }
        }
        return 0
    }
}
