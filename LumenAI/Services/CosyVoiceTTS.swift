import Foundation
import Combine
import CosyVoiceTTS

/// 本地语音引擎 **CosyVoice3**（MLX / Metal GPU）。
///
/// 这是与 Kokoro 完全不同的第二条技术路线：
///   · Kokoro   —— sherpa-onnx，ONNX Runtime，CPU，82M，365 个文件（含 18MB espeak 数据）
///   · CosyVoice3 —— 本项目改用 speech-swift 的 **MLX Swift** 实现，Metal GPU，0.5B 端到端，
///                  不需要 espeak、不需要外部分词/音素化（文本前端在模型内）
///
/// 为什么值得再加一套而不是替换 Kokoro：两者的失败模式完全不同。
/// Kokoro 出问题时会「静默无声」，而它和 CosyVoice 除了音频会话之外**没有任何共用代码**——
/// 一条路线出问题另一条仍可用，这对"语音放不出来"这类难查的问题是有价值的冗余。
///
/// ⚠️ 本机（Intel Mac）**无法运行验证**：MLX 只支持 Apple Silicon。
/// 这里能保证的是「为 iOS 编译并链接通过」与「逻辑正确」，
/// 真机行为必须实测 —— 所以失败路径都做了明确的错误上报，不静默。
@MainActor
final class CosyVoiceTTSManager: ObservableObject {

    static let shared = CosyVoiceTTSManager()

    enum State: Equatable {
        case idle
        case downloading(Double, String)   // 进度 0~1, 当前文件
        case loading
        case ready
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// 供 UI 显示的最近一次错误（合成失败等）
    @Published var lastError: String?

    private var engine: CosyVoiceTTSModel?
    private var speakerEncoder: CamPlusPlusSpeaker?
    private var loadTask: Task<Void, Never>?

    private init() {}

    // MARK: - 路径

    /// 模型根目录：与其它本地模型放在一起，便于「设置 → 存储」统一清理
    nonisolated static var modelDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models/CosyVoice3", isDirectory: true)
    }

    /// 音色克隆模型的独立子目录 —— CAM++ 的加载器会在它自己的 cacheDir 下找
    /// `CamPlusPlus.mlmodelc`，所以必须单独放一层，不能和其它文件混在一起。
    nonisolated static var cloneDirectory: URL {
        modelDirectory.appendingPathComponent("clone", isDirectory: true)
    }

    // MARK: - 就绪判定

    /// 必需文件是否齐全。
    ///
    /// 校验同时接受**清单值**和**实际文件不小于清单值**两种情况：上游偶尔会重导模型
    /// 导致字节数变化，若只认死值，用户的模型会永远被判定为"损坏"而无法使用
    ///（Kokoro 那边就吃过这个亏，所以这里一开始就按宽容策略写）。
    nonisolated static func missingFiles(includeOptional: Bool = false) -> [CosyVoiceManifest.Entry] {
        let fm = FileManager.default
        var needing = CosyVoiceManifest.required
        if includeOptional { needing += CosyVoiceManifest.optional }
        return needing.filter { entry in
            let url = destination(for: entry)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { return true }
            return size < entry.size
        }
    }

    nonisolated static func isReadyToLoad() -> Bool { missingFiles().isEmpty }

    nonisolated static func destination(for entry: CosyVoiceManifest.Entry) -> URL {
        modelDirectory.appendingPathComponent(entry.localPath)
    }

    // MARK: - 下载

    /// 下载模型（魔搭优先）。可选部分单独控制，让用户能先只下 740MB 用起来。
    func download(includeOptional: Bool = false) {
        if case .downloading = state { return }
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            await self.performDownload(includeOptional: includeOptional)
        }
    }

    private func performDownload(includeOptional: Bool) async {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.modelDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Self.cloneDirectory, withIntermediateDirectories: true)

        var entries = CosyVoiceManifest.required
        if includeOptional { entries += CosyVoiceManifest.optional }
        // 音色克隆模型很小（14MB），一并带上 —— 不下的话"克隆音色"这个卖点是空的
        entries += CosyVoiceManifest.cloneModel

        let missing = entries.filter { entry in
            let url = Self.destination(for: entry)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value else { return true }
            return size < entry.size
        }
        guard !missing.isEmpty else {
            state = .ready
            return
        }

        for (index, entry) in missing.enumerated() {
            if Task.isCancelled { state = .idle; return }
            let base = Double(index) / Double(missing.count)
            state = .downloading(base, entry.remotePath)
            do {
                try await Self.downloadEntry(entry) { [weak self] fraction in
                    Task { @MainActor in
                        self?.state = .downloading(base + fraction / Double(missing.count), entry.remotePath)
                    }
                }
            } catch {
                // 单个文件失败就停下并说明是哪个 —— 继续下完剩下的只会让用户
                // 面对一个"下完了但用不了"的模型，比直接说清楚更糟。
                state = .failed("下载「\(entry.remotePath)」失败：\(error.localizedDescription)")
                return
            }
        }
        state = .ready
    }

    /// 下载单个文件。
    ///
    /// 源顺序与模型下载保持一致：**魔搭优先**（实测 4.97MB/s 且稳定），
    /// 再退到 hf-mirror、最后直连 HuggingFace。
    nonisolated private static func downloadEntry(
        _ entry: CosyVoiceManifest.Entry,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let dest = destination(for: entry)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        var lastError: Error?
        for source in CosyVoiceManifest.sources(for: entry) {
            do {
                try await RetryPolicy.run(attempts: 3, label: "cosyvoice:\(entry.remotePath)") {
                    try await downloadFile(from: source, to: dest, expected: entry.size, onProgress: onProgress)
                }
                return
            } catch {
                lastError = error
                // 换源：404 属于"这个源没有"，不该退避重试（见 ModelManager 的同类处理）
                continue
            }
        }
        throw lastError ?? URLError(.cannotLoadFromNetwork)
    }

    nonisolated private static func downloadFile(
        from url: URL, to dest: URL, expected: Int64,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        // 已完整就直接返回（重试时能跳过已完成的部分）
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value, size >= expected {
            onProgress(1); return
        }
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let total = http.expectedContentLength > 0 ? http.expectedContentLength : expected
        var data = Data()
        data.reserveCapacity(Int(min(total, 64 * 1024 * 1024)))
        var lastReport = 0
        for try await byte in bytes {
            data.append(byte)
            if data.count - lastReport > 512 * 1024 {
                lastReport = data.count
                onProgress(total > 0 ? Double(data.count) / Double(total) : 0)
            }
        }
        // 先写临时文件再原子替换：中途失败不会留下"看起来存在、其实是半个"的文件
        let tmp = dest.appendingPathExtension("part")
        try data.write(to: tmp, options: .atomic)
        _ = try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        onProgress(1)
    }

    // MARK: - 引擎加载

    /// 加载引擎（幂等）。设备不满足条件时**直接抛出可读原因**，而不是让 MLX 在运行中崩。
    func loadEngine() async throws -> CosyVoiceTTSModel {
        if let engine { return engine }

        let verdict = LocalVoiceCapability.verdict(for: .cosyVoice)
        if case .unsupported(let why) = verdict {
            throw CosyVoiceError.deviceUnsupported(why)
        }
        let missing = Self.missingFiles()
        guard missing.isEmpty else {
            throw CosyVoiceError.notDownloaded(missing.map(\.remotePath))
        }

        state = .loading
        // offlineMode：模型由**我们自己的下载器**从魔搭取（国内快且稳），
        // 不让它去 HuggingFace 拉 —— 那条线路实测只有 150KB/s，1.2GB 要下两个小时。
        let model = try await CosyVoiceTTSModel.fromPretrained(
            modelId: CosyVoiceManifest.repoID,
            cacheDir: Self.modelDirectory,
            offlineMode: true
        )
        engine = model
        state = .ready
        return model
    }

    /// 取说话人编码器（音色克隆用），首次调用时加载 Core ML 模型。
    func loadSpeakerEncoder() async throws -> CamPlusPlusSpeaker {
        if let speakerEncoder { return speakerEncoder }
        let enc = try await CamPlusPlusSpeaker.fromPretrained(
            modelId: CosyVoiceManifest.cloneModelID,
            cacheDir: Self.cloneDirectory,
            offlineMode: true
        )
        speakerEncoder = enc
        return enc
    }

    /// 把模型包成可跨并发域传递的串行盒子。
    ///
    /// 为什么需要它：`Task.detached` 要求闭包是 `@Sendable`，而 MLX 的模型对象
    /// **不是 Sendable** —— 它内部持有 Metal 缓冲和可变状态。这不是可以靠强转绕过的
    /// 形式问题：并发调用同一个 MLX 模型会真的写坏内部状态。
    ///
    /// 所以这里用 `@unchecked Sendable` **显式承担**「我们保证串行访问」的责任，
    /// 并用一把锁把保证落到实处 —— 而不是让编译器以为它是安全的。
    private static var engineBoxes: [ObjectIdentifier: EngineBox] = [:]

    private static func box(for model: CosyVoiceTTSModel) -> EngineBox {
        let key = ObjectIdentifier(model)
        if let existing = engineBoxes[key] { return existing }
        let created = EngineBox(model)
        engineBoxes[key] = created
        return created
    }

    /// 释放内存（用户切走或内存告警时调用）
    func unload() {
        engine = nil
        speakerEncoder = nil
        cachedEmbedding = nil
        if state == .ready { state = .idle }
    }

    // MARK: - 合成

    /// 合成一段语音，返回 24kHz 单声道样本。`text` 建议是**一句话**，不是整段 ——
    /// 见 `SpeechChunker`：整段合成完才出声是「点了半天没反应」的根因。
    ///
    /// `speakerEmbedding` 非空时做**音色克隆**。
    ///
    /// ⚠️ 这里刻意**收嵌入而不是收参考音频**。原来传的是原始音频、在函数内部现算嵌入，
    /// 有两个后果：(a) `embed` 内部要重采样 + 提 80 维 mel + 跑一次 CoreML 推理，
    /// 是同步重活，而本类型是 `@MainActor` —— 它会卡住界面；
    /// (b) 分句朗读时每一句都要重算一遍，长文本会卡到不可用。
    /// 现在嵌入由 `speakerEmbedding(audio:sampleRate:signature:)` 单独算、按指纹缓存，
    /// 整段朗读只算一次。
    func synthesize(
        text: String,
        language: String = "chinese",
        speakerEmbedding: [Float]? = nil
    ) async throws -> [Float] {
        let model = try await loadEngine()
        let box = Self.box(for: model)
        let embedding = speakerEmbedding
        let samples = await Task.detached(priority: .userInitiated) { [box] in
            box.synthesize(text: text, language: language, embedding: embedding)
        }.value
        guard !samples.isEmpty else {
            throw CosyVoiceError.synthFailed("合成结果为空（模型返回了 0 个采样点）")
        }
        return samples
    }

    /// 计算说话人嵌入（音色克隆用），按 `signature` 缓存。
    ///
    /// **重活全部在 main actor 之外**：CAM++ 的 `embed` 是一个同步调用，里面包含
    /// 重采样、80 维 mel 提取和一次 CoreML 推理。放在 `@MainActor` 上会直接卡住 UI。
    func speakerEmbedding(
        audio: [Float],
        sampleRate: Int,
        signature: String
    ) async throws -> [Float] {
        if let cached = cachedEmbedding, cached.signature == signature {
            return cached.embedding
        }
        let encoder = try await loadSpeakerEncoder()
        let box = Self.encoderBox(for: encoder)
        let embedding = try await Task.detached(priority: .userInitiated) {
            try box.embed(audio: audio, sampleRate: sampleRate)
        }.value
        cachedEmbedding = (signature, embedding)
        return embedding
    }

    /// 嵌入缓存。参考音频不变就只算一次 —— 一次朗读里它不可能变。
    private var cachedEmbedding: (signature: String, embedding: [Float])?

    /// 预热：只加载引擎，不合成。
    ///
    /// 存在的理由：首次加载要编译 Metal 着色器（几十秒）。如果等用户点「朗读」
    /// 才开始加载，那几十秒就是他眼里的「点了没反应」。启动时后台预热掉，
    /// 真正朗读时只剩合成时间。
    ///
    /// 但**只在模型已就绪且设备支持时**才真的加载 —— 否则启动就白吃 1GB 内存，
    /// 反而更容易被系统杀掉。
    func preload() async {
        guard Self.isReadyToLoad() else { return }
        guard LocalVoiceCapability.verdict(for: .cosyVoice).canUse else { return }
        _ = try? await loadEngine()
    }

    private static var encoderBoxes: [ObjectIdentifier: EncoderBox] = [:]

    private static func encoderBox(for encoder: CamPlusPlusSpeaker) -> EncoderBox {
        let key = ObjectIdentifier(encoder)
        if let existing = encoderBoxes[key] { return existing }
        let created = EncoderBox(encoder)
        encoderBoxes[key] = created
        return created
    }
}

/// CAM++ 说话人编码器的串行访问盒子。
///
/// 与 `EngineBox` 同样的理由：`CamPlusPlusSpeaker` 持有 CoreML `MLModel`，
/// 不是 `Sendable`，而 `Task.detached` 要求闭包是 `@Sendable`。
/// 这里用锁**显式承担**「保证串行访问」的责任，而不是强转绕过编译器。
private final class EncoderBox: @unchecked Sendable {
    private let encoder: CamPlusPlusSpeaker
    private let lock = NSLock()

    init(_ encoder: CamPlusPlusSpeaker) { self.encoder = encoder }

    func embed(audio: [Float], sampleRate: Int) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return try encoder.embed(audio: audio, sampleRate: sampleRate)
    }
}

/// MLX 模型的串行访问盒子（见 `CosyVoiceTTSManager.box(for:)` 的说明）。
///
/// 用锁而不是 actor：合成是**同步阻塞**调用（一次几百毫秒到数秒），
/// 放进 actor 只会把阻塞搬到另一个执行器上，并不会让它变得可并发 ——
/// 反而会让「正在合成」这件事在 actor 队列里排队，看起来像卡死。
private final class EngineBox: @unchecked Sendable {
    private let model: CosyVoiceTTSModel
    private let lock = NSLock()

    init(_ model: CosyVoiceTTSModel) { self.model = model }

    /// 合成。同一时刻只允许一个调用进入模型。
    func synthesize(text: String, language: String, embedding: [Float]?) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        if let embedding {
            return model.synthesize(text: text, language: language, speakerEmbedding: embedding)
        }
        return model.synthesize(text: text, language: language)
    }
}

enum CosyVoiceError: Error, LocalizedError {
    case deviceUnsupported(String)
    case notDownloaded([String])
    case synthFailed(String)

    var errorDescription: String? {
        switch self {
        case .deviceUnsupported(let why):
            return why
        case .notDownloaded(let files):
            return "CosyVoice3 模型还不完整，缺少 \(files.count) 个文件（\(files.prefix(3).joined(separator: "、"))…）。"
                 + "请到「设置 → 语音」里下载。"
        case .synthFailed(let why):
            return "CosyVoice3 合成失败：\(why)"
        }
    }
}

/// CosyVoice3 的文件清单与下载源。
///
/// 结构上刻意与 Kokoro 的清单保持一致的思路：**每个文件都带预期字节数**，
/// 用于下载后校验与"缺哪个文件"的精确报告。区别在于这份清单只有 13 个条目、
/// 且没有任何目录级依赖（不需要 espeak-ng-data 那种几百个文件的数据目录）。
enum CosyVoiceManifest {

    struct Entry: Sendable, Equatable {
        /// 远端仓库里的路径
        let remotePath: String
        /// 落到本地的相对路径（允许与远端不同 —— 克隆模型需要单独一层目录）
        let localPath: String
        /// 预期字节数
        let size: Int64
    }

    static let repoID = "luozx123/cosyvoice3-mlx-4bit"
    static let cloneModelID = "luozx123/cosyvoice3-mlx-4bit"

    /// 必需文件合计 740.5 MiB。
    ///
    /// 上游 speech-swift 只放行 8-bit 与 bf16 两种权重布局，遇到 4-bit
    /// 会在加载时直接抛错（"must be 8-bit quantized or 16-bit/bf16 plain Linear"）。
    /// 但 MLX 本身原生支持 4-bit 的 `QuantizedLinear`，这条限制只是加载器
    /// 读 `config.json` 的 `quantization.bits` 时写得过死；而 4-bit 包的
    /// `config.json` 又**只声明了 LLM**、没有 `dit_quantization`，DiT 会被
    /// 按 8-bit 默认值去校验 4-bit 张量。所以本项目改的是加载器：
    /// **从 `(weight, scales)` 的形状反推真实位宽**，让声明值不再是唯一依据。
    /// 这样用户已经下好的 4-bit 包无需重下即可使用。
    ///
    /// `flow_noise.bin` 值得单独说明：4bit 仓库里**没有**这个文件（只有 bf16 仓库有）。
    /// 缺了它，模型不会报错，而是退化成"确定性键控噪声"—— 也就是能出声、但音质与上游
    /// 不一致。这种"能用但不对"的差异最难发现，所以镜像时把它一并取来补齐。
    static let required: [Entry] = [
        Entry(remotePath: "llm.safetensors",        localPath: "llm.safetensors",        size: 489_278_536),
        Entry(remotePath: "flow.safetensors",       localPath: "flow.safetensors",       size: 194_964_136),
        Entry(remotePath: "hifigan.safetensors",    localPath: "hifigan.safetensors",    size: 83_086_548),
        Entry(remotePath: "vocab.json",             localPath: "vocab.json",             size: 2_776_833),
        Entry(remotePath: "merges.txt",             localPath: "merges.txt",             size: 1_402_109),
        Entry(remotePath: "tokenizer_config.json",  localPath: "tokenizer_config.json",  size: 1_287),
        Entry(remotePath: "config.json",            localPath: "config.json",            size: 2_013),
        Entry(remotePath: "weight_shapes.json",     localPath: "weight_shapes.json",     size: 138_913),
        Entry(remotePath: "flow_noise.bin",         localPath: "flow_noise.bin",         size: 4_800_000),
    ]

    /// 可选：461.6 MiB。有了它，克隆从「192 维说话人嵌入」（相似度上限约 0.83）
    /// 升级为上游的零样本条件（prompt_token + prompt_feat），换了情绪也不丢音色。
    /// 做成可选是因为它占了整个模型体积的近四成，而很多人并不用克隆。
    static let optional: [Entry] = [
        Entry(remotePath: "speech_tokenizer.safetensors",
              localPath: "speech_tokenizer.safetensors", size: 484_039_728),
    ]

    /// 音色克隆用的 CAM++ 说话人编码器（Core ML，14MB）。
    /// 注意 localPath 多了一层 `clone/`：它的加载器会在自己的 cacheDir 下找
    /// `CamPlusPlus.mlmodelc`，与主模型混放会找不到。
    static let cloneModel: [Entry] = [
        Entry(remotePath: "CamPlusPlus.mlmodelc/weights/weight.bin",
              localPath: "clone/CamPlusPlus.mlmodelc/weights/weight.bin", size: 13_932_672),
        Entry(remotePath: "CamPlusPlus.mlmodelc/model.mil",
              localPath: "clone/CamPlusPlus.mlmodelc/model.mil", size: 755_748),
        Entry(remotePath: "CamPlusPlus.mlmodelc/metadata.json",
              localPath: "clone/CamPlusPlus.mlmodelc/metadata.json", size: 2_015),
        Entry(remotePath: "CamPlusPlus.mlmodelc/coremldata.bin",
              localPath: "clone/CamPlusPlus.mlmodelc/coremldata.bin", size: 381),
        Entry(remotePath: "CamPlusPlus.mlmodelc/analytics/coremldata.bin",
              localPath: "clone/CamPlusPlus.mlmodelc/analytics/coremldata.bin", size: 243),
    ]

    /// 下载源，按实测速度排序。与 `AIModelInfo.downloadSources` 同一策略：
    /// 魔搭（我们自己的镜像，国内 4.97MB/s）→ hf-mirror → 直连。
    static func sources(for entry: CosyVoiceManifest.Entry) -> [URL] {
        var out: [URL] = []
        let path = entry.remotePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.remotePath
        if let ms = URL(string: "https://modelscope.cn/models/\(repoID)/resolve/master/\(path)") {
            out.append(ms)
        }
        if let hf = URL(string: "https://hf-mirror.com/\(repoID)/resolve/main/\(path)") {
            out.append(hf)
        }
        if let direct = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(path)") {
            out.append(direct)
        }
        return out
    }

    static var requiredBytes: Int64 { required.reduce(0) { $0 + $1.size } }
    static var optionalBytes: Int64 { optional.reduce(0) { $0 + $1.size } }
}
