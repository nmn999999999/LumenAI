import Foundation
import AVFoundation
import Combine

/// 音色克隆的**参考音频**管理。
///
/// CosyVoice3 的克隆是「给一段参考音频 → 提取 192 维说话人嵌入 → 用这个嵌入条件生成」，
/// 所以整个功能的前提是：能把用户给的一小段音频读成 `[Float]` 单声道样本。
/// App 里原本没有这样的工具（ASR 那条路是实时录音、不落文件），所以这里补上。
///
/// 三个设计决定，都是为了不让用户撞上「明明操作对了却没效果」：
///
/// 1. **把参考音频复制进 App 沙盒**，而不是记住用户选的那个路径。
///    `fileImporter` 返回的是「安全作用域书签」资源，出了那次回调就可能失效 ——
///    如果只存路径，表现是「当时试听好好的，下次打开就克隆不出来了」。
///
/// 2. **解码后缓存样本**。参考音频每次合成都用得到，而解码一个几秒的文件
///    每次朗读都重做一遍是纯浪费；缓存按文件修改时间失效，不做复杂的失效逻辑。
///
/// 3. **明确给出时长建议**。克隆质量对参考音频长度敏感，太短（<3 秒）提取出的
///    嵌入不稳，太长则纯属浪费 —— 引擎内部只用到前若干秒。与其让用户猜，
///    不如在界面上直接说清楚，并在过短时给出警告而不是静默接受。
@MainActor
final class CosyVoiceVoiceStore: ObservableObject {

    static let shared = CosyVoiceVoiceStore()

    /// 建议的参考音频时长区间（秒）。
    /// 依据：CAM++ 提取的是全局说话人嵌入，几秒的语音已足以刻画音色；
    /// 太短则嵌入不稳定（同一人两次录会得到不同音色），太长不增加信息量。
    static let recommendedSeconds: ClosedRange<Double> = 5...20

    @Published private(set) var referenceName: String?
    @Published private(set) var referenceSeconds: Double = 0
    @Published private(set) var lastImportError: String?

    private var cachedSamples: [Float]?
    private var cachedRate: Int = 0
    private var cachedStamp: Date?

    private static let key = "cosyvoice.referenceFileName"

    private init() {
        referenceName = UserDefaults.standard.string(forKey: Self.key)
        if referenceName != nil {
            // 预热时长显示；失败就当没有（文件可能被"清理存储"删掉了）
            if let (s, r) = try? loadReferenceSamples() {
                referenceSeconds = Double(s.count) / Double(max(r, 1))
            }
        }
    }

    /// 参考音频存放目录：跟模型放一起，便于统一清理
    nonisolated static var referenceDirectory: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models/CosyVoice3/reference", isDirectory: true)
    }

    var hasReference: Bool { referenceName != nil }

    /// 导入一段参考音频（通常来自「文件」App 或录音导出）。
    ///
    /// 会**先解码校验再落盘**：如果这个文件根本读不出音频（比如用户选了个 PDF），
    /// 应当在那一步就失败并说清楚，而不是复制进去、之后每次朗读都静默地克隆不出来。
    func importReference(from url: URL) {
        lastImportError = nil
        // fileImporter 给的是安全作用域 URL，必须成对开启/关闭
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let (samples, rate) = try Self.decode(url: url)
            guard !samples.isEmpty, rate > 0 else {
                throw VoiceReferenceError.noAudioTrack
            }
            let seconds = Double(samples.count) / Double(rate)

            let fm = FileManager.default
            try fm.createDirectory(at: Self.referenceDirectory, withIntermediateDirectories: true)
            // 统一存成 wav：不依赖用户原文件的容器格式，也不会因为原文件被移走而失效
            let dest = Self.referenceDirectory.appendingPathComponent("reference.wav")
            try? fm.removeItem(at: dest)
            try Self.writeWAV(samples: samples, sampleRate: rate, to: dest)

            referenceName = dest.lastPathComponent
            referenceSeconds = seconds
            UserDefaults.standard.set(referenceName, forKey: Self.key)
            cachedSamples = samples
            cachedRate = rate
            cachedStamp = nil
        } catch {
            lastImportError = "这段音频读不出来：\(error.localizedDescription)"
        }
    }

    /// 读取参考音频样本（带缓存）。没有参考音频时返回 nil。
    func loadReferenceSamples() throws -> ([Float], Int)? {
        guard let loaded = try loadReference() else { return nil }
        return (loaded.samples, loaded.rate)
    }

    /// 读取参考音频，并带上一个**指纹**。
    ///
    /// 指纹是给「说话人嵌入缓存」当 key 用的。光比样本数不够 ——
    /// 换一段时长恰好相同的音频会命中旧缓存，克隆出上一个人的音色，
    /// 而且是静默的（用户只会觉得"换了个参考音频怎么没变化"）。
    /// 所以用「文件名 + 修改时间 + 样本数」三者一起。
    func loadReference() throws -> (samples: [Float], rate: Int, signature: String)? {
        guard let name = referenceName else { return nil }
        let url = Self.referenceDirectory.appendingPathComponent(name)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = attrs?[.modificationDate] as? Date

        let samples: [Float]
        let rate: Int
        if let cached = cachedSamples, stamp == cachedStamp {
            samples = cached
            rate = cachedRate
        } else {
            (samples, rate) = try Self.decode(url: url)
            cachedSamples = samples
            cachedRate = rate
            cachedStamp = stamp
        }
        let signature = "\(name)#\(stamp?.timeIntervalSince1970 ?? 0)#\(samples.count)"
        return (samples, rate, signature)
    }

    /// 供界面报告「选择文件」阶段的失败（该阶段不经过 `importReference`）。
    func setImportError(_ message: String) {
        lastImportError = message
    }

    func clear() {
        if let name = referenceName {
            try? FileManager.default.removeItem(
                at: Self.referenceDirectory.appendingPathComponent(name))
        }
        referenceName = nil
        referenceSeconds = 0
        cachedSamples = nil
        cachedRate = 0
        cachedStamp = nil
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// 对参考音频时长的提示（nil = 正常）。
    var durationHint: String? {
        guard hasReference else { return nil }
        if referenceSeconds < Self.recommendedSeconds.lowerBound {
            return "参考音频只有 \(String(format: "%.1f", referenceSeconds)) 秒，偏短 —— "
                 + "提取出的音色可能不稳定（同一段语音每次听起来略有不同）。建议 5~20 秒。"
        }
        if referenceSeconds > Self.recommendedSeconds.upperBound {
            return "参考音频 \(String(format: "%.0f", referenceSeconds)) 秒，偏长。"
                 + "超出的部分不会被用到，不影响效果，只是可以剪短一些。"
        }
        return nil
    }

    // MARK: - 解码 / 编码

    /// 解码任意受支持格式为单声道 Float32。
    ///
    /// 用 `AVAudioFile` 而不是 `AVAssetReader`：前者对 wav/m4a/mp3/caf 都能直接读，
    /// 而且 `processingFormat` 已经是 Float32 非交错格式，省掉手写转换。
    /// 多声道时**取平均**而不是只取第一个声道 —— 只取一个声道在"人声在右声道"
    /// 这类素材上会得到几乎无声的参考音频，克隆出来自然不像。
    nonisolated static func decode(url: URL) throws -> ([Float], Int) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0 else { throw VoiceReferenceError.noAudioTrack }

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw VoiceReferenceError.decodeFailed("无法分配音频缓冲")
        }
        try file.read(into: buffer)
        guard let channels = buffer.floatChannelData else {
            throw VoiceReferenceError.decodeFailed("音频不是可读的浮点格式")
        }
        let count = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)
        var out = [Float](repeating: 0, count: count)
        if channelCount == 1 {
            out.withUnsafeMutableBufferPointer { dst in
                dst.baseAddress?.update(from: channels[0], count: count)
            }
        } else {
            for i in 0..<count {
                var sum: Float = 0
                for c in 0..<channelCount { sum += channels[c][i] }
                out[i] = sum / Float(channelCount)
            }
        }
        return (out, Int(format.sampleRate))
    }

    /// 写 16bit PCM WAV（与 `WAVWriter` 同一格式，便于统一处理）
    nonisolated static func writeWAV(samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data()
        let dataSize = samples.count * 2
        func ap<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); ap(Int32(36 + dataSize).littleEndian)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        ap(Int32(16).littleEndian); ap(Int16(1).littleEndian); ap(Int16(1).littleEndian)
        ap(Int32(sampleRate).littleEndian); ap(Int32(sampleRate * 2).littleEndian)
        ap(Int16(2).littleEndian); ap(Int16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); ap(Int32(dataSize).littleEndian)
        for v in samples {
            let clamped = max(-1, min(1, v))
            ap(Int16(clamped * 32767).littleEndian)
        }
        try data.write(to: url, options: .atomic)
    }
}

enum VoiceReferenceError: Error, LocalizedError {
    case noAudioTrack
    case decodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return "这个文件里没有可用的音频轨道（可能是空的，或者根本不是音频）。"
        case .decodeFailed(let why):
            return why
        }
    }
}
