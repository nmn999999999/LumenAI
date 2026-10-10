import Foundation

@MainActor
final class ModelManager: ObservableObject {

    static let shared = ModelManager()

    /// 已下载到本地的模型
    @Published private(set) var downloadedModels: [StoredModel] = []
    /// 下载进度（key = AIModelInfo.id 或自定义 key）
    @Published private(set) var progress: [String: Double] = [:]
    @Published var lastError: String?
    /// 最近一次「下载完成」的模型 id（供启动引导在默认模型下载完后自动加载）。
    @Published private(set) var lastCompletedDownloadID: String?

    private var activeTasks: [String: Task<Void, Never>] = [:]
    private var sessions: [String: URLSession] = [:]
    private static let lastModelKey = "model.last.used.v1"

    // MARK: - 后台下载（切后台不断、失败自动重试）

    /// 后台会话的标识。**必须与 App 重启后重建时用的完全一致** ——
    /// 系统是靠这个字符串把"上次没传完的传输"交还给我们的；换一个字符串
    /// 等于把之前所有未完成的下载静默丢弃（而且不会有任何报错）。
    static let backgroundSessionID = "com.lumenai.app.model-download"

    /// 一个待完成/进行中的下载。
    ///
    /// 为什么必须**落盘**：后台会话的意义就是"App 被杀掉之后传输仍然在继续，
    /// 完成后系统把 App 拉起来交付结果"。如果这份清单只存在内存里，App 被系统回收后
    /// 就没有任何东西知道那个传输对应哪个模型、该存到哪个文件名 ——
    /// 结果就是文件传完了却无处安放，用户看到进度条消失、模型列表里什么都没有。
    struct PendingDownload: Codable, Sendable {
        let id: String
        let name: String
        let fileName: String
        /// 当前正在用的源（保留它，是为了让清单在旧版本存档上也能解码出来）
        var remote: URL
        /// 全部候选源，按实测速度排序
        var sources: [URL] = []
        /// 正在用第几个源
        var sourceIndex: Int = 0
        /// 在**当前这个源**上已经重试了几次
        var attempts: Int = 0

        /// 真正要请求的地址。`sources` 为空（旧存档）时退回 `remote`。
        var currentURL: URL? {
            guard !sources.isEmpty else { return remote }
            return sourceIndex < sources.count ? sources[sourceIndex] : nil
        }
        /// 还有没有下一个源可换
        mutating func advanceSource() -> Bool {
            let next = sourceIndex + 1
            guard next < sources.count else { return false }
            sourceIndex = next
            // ⚠️ 换源必须把重试计数清零：新源是新机会，沿用旧计数会让"第二个源"
            // 只试一次就被判失败 —— 而它其实可能完全没问题。
            attempts = 0
            remote = sources[next]
            return true
        }
    }

    /// 未完成的下载（key = 模型 id）。落盘在 Documents/Models/pending.json。
    private(set) var pending: [String: PendingDownload] = [:]
    /// 后台会话的委托，必须由本对象**强引用**着 ——
    /// URLSession 只弱引用 delegate，委托一释放，回调就全都不来了（下载还在跑，静默无进度）。
    private var backgroundDelegate: BackgroundDownloadDelegate?
    private var backgroundSession: URLSession?

    private var pendingURL: URL {
        Self.modelsDirectory.appendingPathComponent("pending.json")
    }

    struct StoredModel: Codable, Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let fileName: String
        let sizeBytes: Int64
        let addedAt: Date
    }

    // MARK: - 目录

    static var modelsDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL {
        Self.modelsDirectory.appendingPathComponent("index.json")
    }

    private init() {
        loadIndex()
        loadPending()
        // 启动就重建后台会话：系统可能在我们没运行时把未完成的传输传完了，
        // 一重建会话它就会通过 delegate 把这些事件补投给我们。
        // 不重建的话，那些传输的结果永远不会被交付 —— 文件在系统临时目录里被清掉，
        // 而用户那边只是"进度条不见了"。
        _ = backgroundSessionHandle
    }

    // MARK: - 查询

    func isDownloaded(_ model: AIModelInfo) -> Bool {
        downloadedModels.contains { $0.id == model.id }
    }

    func progressFor(_ id: String) -> Double? {
        progress[id]
    }

    func localFileURL(fileName: String) -> URL {
        Self.modelsDirectory.appendingPathComponent(fileName)
    }

    func localFileURL(for stored: StoredModel) -> URL {
        localFileURL(fileName: stored.fileName)
    }

    // MARK: - 最后使用的模型（退出后自动记住）

    private static func lastModelID() -> String? {
        UserDefaults.standard.string(forKey: lastModelKey)
    }

    /// 记录最近一次加载的模型，供下次启动自动加载。
    func rememberLastUsed(_ stored: StoredModel) {
        UserDefaults.standard.set(stored.id, forKey: Self.lastModelKey)
    }

    /// 最近使用的模型（若文件还在则返回）。
    var lastUsedModel: StoredModel? {
        guard let id = Self.lastModelID() else { return nil }
        return downloadedModels.first(where: { $0.id == id })
    }

    /// 自动检测：扫描 Models 目录把未被索引的 .gguf 文件补进列表。
    private func rescanModelsDirectory() {
        let dir = Self.modelsDirectory
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return }
        for fileURL in files {
            let ext = fileURL.pathExtension.lowercased()
            guard ext == "gguf" || ext == "ggml" || ext == "bin" else { continue }
            let fileName = fileURL.lastPathComponent
            let baseName = (fileName as NSString).deletingPathExtension
            if !downloadedModels.contains(where: { $0.fileName == fileName }) {
                let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                downloadedModels.append(StoredModel(
                    id: "scan-\(fileName)",
                    name: baseName,
                    fileName: fileName,
                    sizeBytes: Int64(size),
                    addedAt: Date()
                ))
            }
        }
        saveIndex()
    }

    // MARK: - 下载（HuggingFace）

    func download(_ model: AIModelInfo) {
        let sources = model.downloadSources
        guard !sources.isEmpty else { return }
        startDownload(id: model.id, name: model.name, fileName: model.fileName, sources: sources)
    }

    func downloadCustom(name: String, remoteURL: URL) {
        let fileName = remoteURL.lastPathComponent
        let id = "custom-\(fileName)"
        // 用户手填的地址只有一个源，且**不该**被替换成别的 —— 那是他自己指定的。
        startDownload(id: id, name: name.isEmpty ? fileName : name,
                      fileName: fileName, sources: [remoteURL])
    }

    // MARK: - 后台下载委托

    /// 后台会话的委托。
    ///
    /// 与原来的实现最大的区别：**一个会话 + 一个委托**，而不是"每个下载一个新会话"。
    /// 后台会话是系统级资源、按 identifier 唯一；每个下载各建一个后台会话会互相打架
    /// （同 identifier 的会话只能存在一个），而且 App 被系统拉起时无法还原出"哪个委托"。
    private final class BackgroundDownloadDelegate: NSObject, URLSessionDownloadDelegate {
        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let key = downloadTask.taskDescription else { return }

            // ⚠️⚠️ 必须**同步**把文件搬走，不能丢进 Task 里异步做。
            //
            // 这是实测踩到的崩溃（用户报的原文）：
            //   "CFNetworkDownload_xxx.tmp" couldn't be moved to "Models" because
            //    either the former doesn't exist, or the folder containing the latter doesn't exist.
            // 原因：`location` 指向系统临时文件，**这个回调一返回系统就把它删掉**。
            // 我之前把它写成 `Task { @MainActor in ... 搬 ... }` —— 等那个 Task 真正跑起来，
            // 临时文件早就没了，于是 moveItem 报"前者不存在"。
            // （更讽刺的是我当时的注释里写着"必须同步搬"，代码却写成异步，注释和实现相反。）
            //
            // 拆成两步是为了绕开 actor 隔离：第一步只做纯文件操作、不碰任何 @MainActor 状态，
            // 所以能在委托线程上同步完成；第二步（改文件名 + 写索引）才回主 actor。
            guard let staged = ModelManager.stageDownloadedFile(id: key, from: location) else {
                Task { @MainActor in
                    ModelManager.shared.lastError = "下载完成但无法保存临时文件（系统临时文件已失效）"
                    ModelManager.shared.downloadFailed(
                        id: key,
                        error: URLError(.cannotCreateFile),
                        resumeData: nil)
                }
                return
            }
            Task { @MainActor in
                ModelManager.shared.deliverStagedFile(id: key, stagedURL: staged)
            }
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard let key = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
            let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            Task { @MainActor in
                ModelManager.shared.progress[key] = value
                // 同步到灵动岛 / 锁屏。用户不必守着 App 看百分比 ——
                // 而"下载极不稳定"这件事本身，锁屏上能看到进度在动就已经缓解了一半焦虑。
                // 节流由 LiveActivityManager 内部做（1 秒），这里不重复判断。
                ModelManager.shared.updateLiveActivityProgress(id: key, value: value)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let key = task.taskDescription else { return }
            let resumeData = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            Task { @MainActor in
                ModelManager.shared.downloadFailed(id: key, error: error, resumeData: resumeData)
            }
        }

        /// 后台会话把所有事件投递完之后回调：**必须**调用系统给的 completionHandler，
        /// 否则系统会认为我们没处理完，之后不再唤起这个 App ——
        /// 表现是"第一次切后台还能下，之后再也收不到完成通知"。
        func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
            Task { @MainActor in
                ModelManager.shared.consumeBackgroundCompletionHandler()
            }
        }
    }

    /// 系统在 `handleEventsForBackgroundURLSession` 里给的完成回调，必须原样存下、
    /// 并在 `urlSessionDidFinishEvents` 时调用。
    nonisolated(unsafe) static var backgroundCompletionHandler: (() -> Void)?

    /// 后台会话（懒建；App 启动时重建它，系统才会把未完成传输的事件补投给我们）
    private var backgroundSessionHandle: URLSession {
        if let backgroundSession { return backgroundSession }
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.backgroundSessionID)
        // 1.1GB 的模型在国内镜像上要下十几分钟，资源级超时给足；
        // 后台会话本就由系统托管调度，不要再叠一层自定义超时。
        cfg.timeoutIntervalForResource = 60 * 60 * 12
        // 允许蜂窝：用户点了下载就是明确意愿。关掉它会让"Wi-Fi 切到 5G"直接中断传输。
        cfg.allowsCellularAccess = true
        cfg.isDiscretionary = false
        cfg.sessionSendsLaunchEvents = true
        let delegate = BackgroundDownloadDelegate()
        // delegate 必须强引用：URLSession 只弱引用它，一释放回调就全不来
        //（下载还在后台跑，只是我们永远收不到进度和完成）
        backgroundDelegate = delegate
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        backgroundSession = session
        return session
    }

    /// App 被系统唤起（或正常启动）时重新接管未完成的传输。
    func reattachBackgroundSession() {
        _ = backgroundSessionHandle
    }

    fileprivate func consumeBackgroundCompletionHandler() {
        let handler = Self.backgroundCompletionHandler
        Self.backgroundCompletionHandler = nil
        handler?()
    }

    // MARK: - 下载

    private func startDownload(id: String, name: String, fileName: String, sources: [URL]) {
        guard let remote = sources.first else { return }
        let destination = localFileURL(fileName: fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            addOrUpdate(stored: StoredModel(
                id: id, name: name, fileName: fileName,
                sizeBytes: fileSize(at: destination), addedAt: Date()
            ))
            clearPending(id: id)
            return
        }
        // 已在待办且正在跑就不重复发起：重复发起会产生**两条**后台传输写同一个目标文件，
        // 后完成的那条覆盖前一条，而进度条会在两条之间来回跳。
        if pending[id] != nil, activeTasks[id] != nil { return }

        // 保留已有的进度（attempts / sourceIndex），避免"重复点下载"把换源进度清零
        let existing = pending[id]
        pending[id] = PendingDownload(
            id: id, name: name, fileName: fileName, remote: remote,
            sources: sources,
            sourceIndex: existing?.sourceIndex ?? 0,
            attempts: existing?.attempts ?? 0
        )
        savePending()
        launch(id: id)
    }

    /// 真正发起一次传输（首次与重试都走这里）
    private func launch(id: String, resumeData: Data? = nil) {
        guard let item = pending[id] else { return }
        progress[id] = progress[id] ?? 0
        // 后台 URLSession 本身由系统托管、挂起后仍会继续；但"把结果搬进沙盒并写索引"
        // 是我们的代码，需要一个短窗口 —— 这里申请保活。
        BackgroundTaskKeeper.shared.begin(.download)
        // 起卡片。放在这里而不是 startDownload：startDownload 可能因为"文件已存在"
        // 直接返回、或者只是在排队，那时并没有真的在下载 —— 提前显示卡片会是假进度。
        LiveActivityManager.shared.start(
            conversationTitle: item.name,
            state: .init(title: "正在下载模型 \(item.name)",
                         phase: .downloading, step: 0, totalSteps: nil,
                         detail: item.fileName, progress: progress[id] ?? 0,
                         startedAt: Date()),
            kind: .download)

        let session = backgroundSessionHandle
        guard let target = item.currentURL else {
            lastError = "所有下载源都不可用"
            clearPending(id: id); finishDownload(id: id); return
        }
        let task: URLSessionDownloadTask
        if let resumeData {
            // 有续传数据就接着下：1.1GB 的模型从 0 重来代价太大，
            // 而 URLSession 在连接中断时通常会给 resumeData。
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: target)
        }
        // 用 taskDescription 携带模型 id：App 被系统拉起时是**另一个进程实例**，
        // 内存里那张 task→模型 的表不存在，只能靠随任务一起被系统保存的字符串。
        task.taskDescription = id
        activeTasks[id] = Task { task.resume() }
    }

    /// 计算 Models 目录并确保它存在（**非隔离**版本）。
    ///
    /// 为什么要单独一个：`modelsDirectory` 是 `@MainActor` 上的静态属性，
    /// 而"搬运系统临时文件"必须在委托线程上**同步**完成，碰不到主 actor。
    /// 两个版本共用同一套路径规则，只是隔离域不同 —— 路径只写一份，避免漂移。
    nonisolated static func modelsDirectoryPath() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 把系统给的临时文件同步搬到我们的暂存区。**必须由下载委托在回调内同步调用。**
    ///
    /// 为什么先搬到暂存区而不是直接搬到最终文件名：最终文件名要从 `pending` 表里查
    /// （那是 @MainActor 状态），而这一步不能跨 actor。暂存区只按 id 命名，纯文件操作。
    nonisolated static func stageDownloadedFile(id: String, from location: URL) -> URL? {
        let fm = FileManager.default
        let staging = modelsDirectoryPath().appendingPathComponent(".staging", isDirectory: true)
        try? fm.createDirectory(at: staging, withIntermediateDirectories: true)
        // id 可能是自定义下载拼出来的，含 "/" 会跑到目录外面去
        let safe = id.replacingOccurrences(of: "/", with: "_")
        let dst = staging.appendingPathComponent(safe)
        try? fm.removeItem(at: dst)   // 同 id 的残留（上次失败留下的）
        do {
            try fm.moveItem(at: location, to: dst)
            return dst
        } catch {
            return nil
        }
    }

    /// 校验刚下好的文件是否真的是模型文件。返回 `nil` = 通过；否则是给用户看的原因。
    ///
    /// 只认 llama.cpp 吃的几种魔数（GGUF / GGML 系列）。**刻意不看扩展名就放行** ——
    /// 扩展名是我们自己按 URL 尾段取的，源站给什么内容都改变不了它，
    /// 所以它是"我们希望它是什么"，不是"它实际是什么"。
    ///
    /// `nonisolated static`：要在委托线程/主 actor 两处都能调，且不碰任何共享状态。
    nonisolated static func rejectReason(forStagedFile url: URL, fileName: String) -> String? {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return "下载到的文件是空的，请换个源重试。" }

        guard let fh = try? FileHandle(forReadingFrom: url) else {
            return "下载的文件读不出来（可能已被系统清理），请重试。"
        }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 4)) ?? Data()

        // 网页 / JSON 错误页：这类内容经常是以 200 返回的，所以状态码拦不住它们。
        let firstByte = head.first.map { Int($0) }
        if firstByte == 0x3C /* < */ || firstByte == 0x7B /* { */ || firstByte == 0x5B /* [ */ {
            return "下载到的不是模型文件，而是一个网页或 JSON 错误内容（通常是登录页或限流提示）。请换一个下载源重试，或先在浏览器里确认该地址能直接下载。"
        }

        let ext = (fileName as NSString).pathExtension.lowercased()
        guard ext == "gguf" || ext == "ggml" || ext == "bin" else { return nil }   // 不认识的类型不拦

        let magic = String(data: head, encoding: .ascii)?.lowercased() ?? ""
        let known = ["gguf", "ggml", "ggmf", "ggjt", "ggla"]
        guard known.contains(magic) else {
            let shown = magic.allSatisfy { $0.isLetter || $0.isNumber } && !magic.isEmpty ? magic : "二进制内容"
            return "下载到的文件不是有效的模型格式（文件头是「\(shown)」）。多半是下载被中断、或源站返回了错误内容，请换个源重试。"
        }

        // 一个真实的 GGUF 不可能只有几百 KB —— 这是"页面/片段被存成模型"的兜底判断。
        if ext == "gguf" && size < 1_048_576 {
            return "模型文件只有 \(size) 字节，明显不完整，请换个源重试。"
        }
        return nil
    }

    /// 把暂存文件挪到最终文件名，并写索引（主 actor 上做）
    fileprivate func deliverStagedFile(id: String, stagedURL: URL) {
        guard let item = pending[id] else {
            try? FileManager.default.removeItem(at: stagedURL)
            return
        }
        let destination = localFileURL(fileName: item.fileName)

        // 先把"这到底是不是一个模型文件"验掉，再往正式目录搬。
        //
        // 为什么这一步不能省：源站完全可能**以 200 返回一个网页**——私有仓库的登录页、
        // 限流的提示页、或"文件不存在"的 HTML 页都是这样。它会被原样存成 .gguf，
        // 之后用户看到的是**加载阶段**报的"未知模型格式 / 文件头不合法"，也就是
        // 在最不相关的地方、用最看不懂的话，报一个其实是下载环节的错。
        // 拦在这里就能直接说清原因，也让「换源重试」这件事变得有的放矢。
        if let why = Self.rejectReason(forStagedFile: stagedURL, fileName: item.fileName) {
            try? FileManager.default.removeItem(at: stagedURL)
            lastError = why
            clearPending(id: id)
            finishDownload(id: id)
            LiveActivityManager.shared.end(state: .init(
                title: "下载的文件不可用",
                phase: .failed, step: 0, totalSteps: nil,
                detail: item.name, progress: nil, startedAt: Date()),
                kind: .download)
            return
        }

        do {
            let fm = FileManager.default
            try? fm.createDirectory(at: destination.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: stagedURL, to: destination)
            addOrUpdate(stored: StoredModel(
                id: id, name: item.name, fileName: item.fileName,
                sizeBytes: fileSize(at: destination), addedAt: Date()
            ))
            lastCompletedDownloadID = id
            clearPending(id: id)
            finishDownload(id: id)
            LiveActivityManager.shared.end(state: .init(
                title: "模型已下载，可以去「本地模型」里加载",
                phase: .done, step: 0, totalSteps: nil,
                detail: item.name, progress: 1, startedAt: Date()),
                kind: .download)
        } catch {
            lastError = "保存文件失败: \(error.localizedDescription)"
            clearPending(id: id)
            finishDownload(id: id)
        }
    }

    /// 把下载进度推给灵动岛（只有当前卡片确实是这次下载时才推）
    fileprivate func updateLiveActivityProgress(id: String, value: Double) {
        guard let item = pending[id] else { return }
        LiveActivityManager.shared.update(.init(
            title: "正在下载模型 \(item.name)",
            phase: .downloading, step: 0, totalSteps: nil,
            detail: "\(Int(value * 100))% · \(item.fileName)",
            progress: value, startedAt: Date()))
    }


    fileprivate func downloadFailed(id: String, error: Error?, resumeData: Data?) {
        // 用户主动取消：不是失败，不重试 —— 重试等于把用户的取消操作撤销
        if let ns = error as NSError?, ns.code == NSURLErrorCancelled {
            clearPending(id: id)
            finishDownload(id: id)
            return
        }
        guard var item = pending[id] else { finishDownload(id: id); return }
        item.attempts += 1

        let retryable = error.map { RetryPolicy.isTransient($0) } ?? false

        // ⚠️ 「换源」和「重试」是两件不同的事，这里必须分开：
        //   · 重试 = 同一个源再试一次。适用于瞬时错误（超时、连接重置、5xx）。
        //   · 换源 = 这个源根本不行（404 没有这个仓库、403 被拒），换一个。
        // 混在一起的后果很具体：某个仓库在魔搭没有镜像，第一个源必然 404；
        // 若把 404 当成"可重试"，这里会对着同一个 404 重试三次、每次还退避等待，
        // 用户要白等七八秒才轮到本来能用的 hf-mirror。
        let sourceExhausted = !retryable || item.attempts > RetryPolicy.defaultAttempts

        if sourceExhausted, item.advanceSource() {
            pending[id] = item
            savePending()
            lastError = "这个下载源不行（第 \(item.sourceIndex) 个），已换下一个源继续"
            // 换源后立刻重来，不退避：新源第一次尝试不该被上一个源的失败拖慢
            Task { @MainActor in
                guard ModelManager.shared.pending[id] != nil else { return }
                ModelManager.shared.launch(id: id)
            }
            return
        }

        if !sourceExhausted {
            pending[id] = item
            savePending()
            let wait = RetryPolicy.delay(attempt: item.attempts)
            lastError = "下载中断，\(Int(wait)) 秒后自动重试（第 \(item.attempts) 次）"
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard ModelManager.shared.pending[id] != nil else { return }
                ModelManager.shared.launch(id: id, resumeData: resumeData)
            }
            return
        }

        lastError = "下载失败（\(item.sources.count) 个源都试过了）: "
            + (error.map { ($0 as NSError).localizedDescription } ?? "未知错误")
        clearPending(id: id)
        finishDownload(id: id)
        LiveActivityManager.shared.end(state: .init(
            title: "模型下载失败", phase: .failed, step: 0, totalSteps: nil,
            detail: lastError, progress: nil, startedAt: Date()),
            kind: .download)
    }

    /// App 启动时把上次没下完的接着下。
    func resumePendingDownloads() {
        for (id, item) in pending {
            let dest = localFileURL(fileName: item.fileName)
            if FileManager.default.fileExists(atPath: dest.path) {
                // 文件其实已经在本地了（重启前传完了、只是索引没写成功）——
                // 这种情况补索引就行，不要再下一次 1.1GB。
                addOrUpdate(stored: StoredModel(
                    id: item.id, name: item.name, fileName: item.fileName,
                    sizeBytes: fileSize(at: dest), addedAt: Date()
                ))
                clearPending(id: id)
                continue
            }
            launch(id: id)
        }
    }

    // MARK: - 待下载清单落盘

    private func loadPending() {
        guard let data = try? Data(contentsOf: pendingURL),
              let decoded = try? JSONDecoder().decode([String: PendingDownload].self, from: data)
        else { return }
        pending = decoded
    }

    private func savePending() {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        try? data.write(to: pendingURL, options: .atomic)
    }

    private func clearPending(id: String) {
        guard pending.removeValue(forKey: id) != nil else { return }
        savePending()
    }

    fileprivate func finishDownload(id: String) {
        sessions[id]?.invalidateAndCancel()
        sessions[id] = nil
        activeTasks[id] = nil
        progress[id] = nil
        // 这一条下载收尾完毕，释放后台保活（没别的下载在跑时才真的释放）
        if activeTasks.isEmpty { BackgroundTaskKeeper.shared.end(.download) }
    }

    func cancelDownload(id: String) {
        // 取消要从待下载清单里一起摘掉，否则下次启动 resumePendingDownloads()
        // 会把它**重新启动** —— 用户明明点了取消，重启后它又自己下起来了。
        clearPending(id: id)
        sessions[id]?.invalidateAndCancel()
        sessions[id] = nil
        activeTasks[id]?.cancel()
        activeTasks[id] = nil
        progress[id] = nil
    }

    // MARK: - 从「文件」导入（用户自行下载的 gguf）

    func importFromFiles(url: URL, name: String?) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let fileName = url.lastPathComponent
        let destination = localFileURL(fileName: fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        addOrUpdate(stored: StoredModel(
            id: "import-\(fileName)",
            name: name ?? (fileName as NSString).deletingPathExtension,
            fileName: fileName,
            sizeBytes: fileSize(at: destination),
            addedAt: Date()
        ))
    }

    // MARK: - 删除

    func delete(_ stored: StoredModel) {
        let fileURL = localFileURL(for: stored)
        try? FileManager.default.removeItem(at: fileURL)
        downloadedModels.removeAll { $0.id == stored.id }
        saveIndex()
    }

    // MARK: - 持久化

    private func addOrUpdate(stored: StoredModel) {
        if let idx = downloadedModels.firstIndex(where: { $0.id == stored.id }) {
            downloadedModels[idx] = stored
        } else {
            downloadedModels.append(stored)
        }
        saveIndex()
    }

    fileprivate func fileSize(at url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func loadIndex() {
        if let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601 // 与 saveIndex 一致，否则 addedAt 解码失败导致索引被清空
            let list = try? decoder.decode([StoredModel].self, from: data)
            downloadedModels = list ?? []
        }
        // 自动检测：把目录里未被索引的 .gguf 文件补进来
        rescanModelsDirectory()
    }

    private func saveIndex() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(downloadedModels) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }
}
