import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// 本地语音引擎的**设备能力判定**。
///
/// 为什么这件事不能省：新的 CosyVoice3 引擎是 0.5B 的 MLX 模型，
/// 运行时权重 + 激活大约占用 1~1.5GB 内存，而且 **MLX 只能在 Apple Silicon 上跑**。
/// 一个 4GB 内存的机器就算把 1.2GB 模型完整下下来，也只会在加载时被系统杀掉 ——
/// 用户看到的是「下完了、点了没反应」，而真正的原因（内存不够）永远看不到。
///
/// 所以这里的定位不是「锦上添花的提示」，而是**在下之前就把不可能的组合拦住**，
/// 并且把理由说成人话。判据只用两样：物理内存和芯片标识。
///
/// 与 `LLMService.recommendedGpuLayers` 的分工：那条管本地 LLM 的 Metal offload 层数，
/// 这条管语音引擎能不能装/能不能跑。两者判据同源（物理内存），但阈值不同 ——
/// 语音模型常驻内存，LLM 的 KV 缓存则是随上下文增长的。
enum LocalVoiceCapability {

    /// 设备芯片标识，如 `iPhone16,1`。取不到时返回 `unknown`。
    static var deviceIdentifier: String {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return "unknown" }
        let mirror = Mirror(reflecting: systemInfo.machine)
        let id = mirror.children.reduce(into: "") { acc, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            acc.append(Character(UnicodeScalar(UInt8(bitPattern: value))))
        }
        return id.isEmpty ? "unknown" : id
    }

    /// 物理内存（GB，向下取整）
    static var ramGB: Int {
        Int(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024))
    }

    /// 是否跑在模拟器里。MLX 需要真实 Metal 设备，模拟器上**不具备**可用的推理能力，
    /// 不区分的话会出现「代码没问题、就是跑不出来」这种最难查的现象。
    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    /// 机型标识 → 对用户友好的名字。
    ///
    /// 只覆盖 iPhone 11 之后（本地语音引擎的现实门槛在这个区间），
    /// 查不到就原样显示标识 —— 显示 `iPhone16,1` 也比显示「未知」有用，
    /// 至少能让用户自己搜到是什么机器。
    static var deviceName: String {
        let id = deviceIdentifier
        if let known = marketingNames[id] { return known }
        if id.hasPrefix("iPhone") { return "iPhone（\(id)）" }
        if id.hasPrefix("iPad") { return "iPad（\(id)）" }
        if id.hasPrefix("Mac") || id.hasPrefix("x86_64") || id.hasPrefix("arm64") {
            return "Mac（\(id)）"
        }
        return id
    }

    /// 一句话设备摘要，给设置页直接显示。
    static var summary: String {
        var parts = ["\(deviceName)", "\(ramGB)GB 内存"]
        if isSimulator { parts.append("模拟器") }
        return parts.joined(separator: " · ")
    }

    // MARK: - 引擎可行性

    enum Verdict: Equatable {
        /// 可以跑
        case supported
        /// 能跑但吃紧，给出提醒（仍然允许，只是要把代价说清）
        case tight(String)
        /// 跑不了，给出原因
        case unsupported(String)

        var canUse: Bool {
            if case .unsupported = self { return false }
            return true
        }

        var message: String? {
            switch self {
            case .supported: return nil
            case .tight(let m), .unsupported(let m): return m
            }
        }
    }

    /// 判定某个引擎在当前设备上是否可行。
    ///
    /// 阈值依据：CosyVoice3 是 0.5B、4bit 权重约 470MB，加上 flow/hifigan/激活，
    /// 常驻占用约 1~1.5GB。iOS 对单进程的内存上限大致是物理内存的一半左右，
    /// 所以 4GB 机器（上限约 2GB）留给模型的空间不足以稳定容纳它；
    /// 6GB（上限约 3GB）能跑但与其他大内存功能（本地 LLM）**不能同时**用；
    /// 8GB 及以上可以从容运行。
    static func verdict(for engine: LocalVoiceEngineKind) -> Verdict {
        if engine == .systemTTS { return .supported }

        if isSimulator {
            return .unsupported("当前运行在模拟器里。MLX 引擎需要真实设备的 Metal 支持，模拟器上无法运行，请在真机上测试。")
        }

        switch engine {
        case .systemTTS:
            return .supported

        case .kokoro:
            // Kokoro 是 82M，占用小，4GB 机器也能跑
            if ramGB < 4 {
                return .unsupported("本地语音（Kokoro）需要至少 4GB 内存，当前设备为 \(ramGB)GB。")
            }
            return .supported

        case .cosyVoice:
            switch ramGB {
            case 8...:
                return .supported
            case 6..<8:
                return .tight("你的设备是 \(ramGB)GB 内存，可以运行 CosyVoice3，但加载后会长期占用约 1~1.5GB。"
                              + "如果同时开着本地大模型，可能会被系统回收 —— 建议两者不要同时使用。")
            default:
                return .unsupported("CosyVoice3 需要至少 6GB 内存（推荐 8GB），当前设备为 \(ramGB)GB。"
                                    + "强行加载会在加载阶段被系统终止，表现为「下完了却没有反应」。"
                                    + "这台设备建议使用 Kokoro 本地语音或系统语音。")
            }
        }
    }

    /// 是否需要下载约 1.2GB 的模型（给设置页显示用）
    static func downloadSizeDescription(for engine: LocalVoiceEngineKind) -> String {
        switch engine {
        case .systemTTS: return "无需下载"
        case .kokoro:    return "约 169 MB"
        case .cosyVoice: return "约 740 MB（可选再加 461 MB 提升克隆保真度）"
        }
    }

    // MARK: - 机型表

    private static let marketingNames: [String: String] = [
        // iPhone 17 系列
        "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air",
        // iPhone 16 系列
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
        // iPhone 15 系列
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        // iPhone 14 系列
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        // iPhone 13 系列
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        // iPhone 12 / SE
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,6": "iPhone SE (3rd)",
        // iPhone 11
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd)",
    ]
}

/// 本地语音引擎种类（与 `ModelSettings.ttsEngine` 的字符串值一一对应）
enum LocalVoiceEngineKind: String, CaseIterable, Identifiable {
    case systemTTS = "system"
    case kokoro = "kokoro"
    case cosyVoice = "cosyvoice"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .systemTTS: return "系统语音"
        case .kokoro:    return "本地 · Kokoro（轻量）"
        case .cosyVoice: return "本地 · CosyVoice3（高音质）"
        }
    }

    var engineDescription: String {
        switch self {
        case .systemTTS:
            return "iOS 内置合成，无需下载、不会失败，但音色不可定制。"
        case .kokoro:
            return "82M 的小模型，CPU 推理，占用小、启动快。云端镜像已就绪。"
        case .cosyVoice:
            return "0.5B 端到端模型，走 MLX（Metal GPU），音质与自然度明显更高，"
                 + "并且支持用一段参考音频克隆音色。需要 6GB 以上内存。"
        }
    }
}
