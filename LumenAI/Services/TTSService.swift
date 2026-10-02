import Foundation
import AVFoundation
import Combine

/// 语音朗读服务（TTS Providers）
/// - 系统 TTS：AVSpeechSynthesizer（离线）
/// - 网络 TTS：OpenAI 兼容 /audio/speech（复用当前 Provider 的 Key 与 BaseURL）
@MainActor
final class TTSService: NSObject, ObservableObject {

    static let shared = TTSService()

    @Published var isSpeaking = false

    private let synthesizer = AVSpeechSynthesizer()
    private var audioPlayer: AVAudioPlayer?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    // MARK: - 朗读

    /// 进行中的网络 TTS 请求。`stop()` 必须能取消它 —— 否则已经发出的请求
    /// 回来之后还会接着把音频播出来（停不掉）。
    private var networkTask: Task<Void, Never>?

    func speak(_ text: String) {
        stop()
        lastSpokenText = text
        let settings = SettingsStorage.shared.settings

        switch settings.ttsEngine {
        case "network":
            networkTask = Task { await speakNetwork(text, settings: settings) }
        case "kokoro":
            Task { await speakKokoro(text, settings: settings) }
        case "cosyvoice":
            Task { await speakCosyVoice(text, settings: settings) }
        default:
            speakSystem(text, settings: settings)
        }
    }

    func stop() {
        kokoroTask?.cancel()
        kokoroTask = nil
        networkTask?.cancel()
        networkTask = nil
        synthesizer.stopSpeaking(at: .immediate)
        audioPlayer?.stop()
        isSpeaking = false
    }

    // MARK: 系统 TTS

    /// 解析系统语音。返回值优先解释为 AVSpeechSynthesisVoice 的 identifier；
    /// 若不匹配则当作语言代码回退（兼容旧存档存的是 "zh-CN" 这类语言代码）。
    static func resolveSystemVoice(_ voiceSetting: String, defaultLanguage: String) -> AVSpeechSynthesisVoice? {
        let v = voiceSetting.trimmingCharacters(in: .whitespaces)
        if !v.isEmpty {
            if let voice = AVSpeechSynthesisVoice(identifier: v) { return voice }
            if let voice = AVSpeechSynthesisVoice(language: v) { return voice }
        }
        return AVSpeechSynthesisVoice(language: defaultLanguage)
    }

    private func speakSystem(_ text: String, settings: ModelSettings) {
        // 系统 TTS 原来**没有**配会话，用的是默认类别（会被静音开关静音）。
        // 本地引擎失败回退到这里时，用户如果正好开着静音开关，
        // 听到的仍然是"没声音"—— 两条路一起哑，现场看起来就是彻底坏了。
        _ = configurePlaybackSession()
        let utterance = AVSpeechUtterance(string: text)
        let lang = settings.language == "en" ? "en-US" : "zh-CN"
        if let voice = Self.resolveSystemVoice(settings.ttsVoice, defaultLanguage: lang) {
            utterance.voice = voice
        }
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        isSpeaking = true
        synthesizer.speak(utterance)
    }

    // MARK: 本地神经 TTS（Kokoro，离线）

    private var kokoroTask: Task<Void, Never>?
    /// 供 UI 读取的最新错误（模型未下载 / 引擎失败等）
    @Published var lastTTSError: String?

    /// 最近一次本地合成的**诊断结论**。
    ///
    /// 为什么要单独有它：用户报「点了没声音」时，"没声音"至少对应三种完全不同的
    /// 原因 —— 引擎没跑起来 / 模型合成出来的就是静音 / 合成正常但播放没出声。
    /// 这三种在界面上原本长得一模一样，只能靠猜。这里把每一步的实测结果记下来，
    /// 让界面直接说出来。
    @Published var lastDiagnostic: String?

    /// 「试听」入口：**强制走 CosyVoice3**，不受当前 `ttsEngine` 设置影响。
    ///
    /// 原来卡片里的试听按钮调的是全局 `speak()`，而 `speak()` 按
    /// `settings.ttsEngine` 分发 —— 也就是说引擎选的是 Kokoro 或系统时，
    /// 在 CosyVoice 卡片里点「试听」测的其实是**另一个引擎**。
    /// 用户看到的是「点了没声音」，而真实原因是被测的根本不是这个引擎。
    func previewCosyVoice(_ text: String) {
        stop()
        lastSpokenText = text
        lastDiagnostic = "正在合成…（首次会先加载引擎，并编译 Metal 着色器，可能要几十秒）"
        let settings = SettingsStorage.shared.settings
        Task { await speakCosyVoice(text, settings: settings) }
    }

    /// 合成结果体检。
    ///
    /// 峰值是最有价值的一项 —— 它能把「模型返回静音」和「播放失败」彻底分开，
    /// 而这两种在用户那头都只表现为「没声音」。
    struct SampleStats {
        let count: Int
        let seconds: Double
        let peak: Float
        let rms: Double
        /// 峰值低到这个程度，基本就是静音而不是"声音小"
        var isSilent: Bool { peak < 0.002 }
        var text: String {
            String(format: "%.2f 秒 · 峰值 %.4f · RMS %.5f · %d 采样",
                   seconds, peak, rms, count)
        }
    }

    nonisolated static func stats(_ samples: [Float], sampleRate: Int) -> SampleStats {
        guard !samples.isEmpty else {
            return SampleStats(count: 0, seconds: 0, peak: 0, rms: 0)
        }
        var peak: Float = 0
        var sumSq: Double = 0
        for value in samples {
            let magnitude = abs(value)
            if magnitude > peak { peak = magnitude }
            sumSq += Double(value) * Double(value)
        }
        return SampleStats(
            count: samples.count,
            seconds: Double(samples.count) / Double(max(sampleRate, 1)),
            peak: peak,
            rms: (sumSq / Double(samples.count)).squareRoot())
    }

    private func speakKokoro(_ text: String, settings: ModelSettings) async {
        guard !text.isEmpty else { return }

        // 模型未就绪：**立刻**说清楚，不要先默默等 1.5 秒。
        // 原来重试 3 次、每次 500ms —— 用户感知是"点了没反应"，然后才听到系统 TTS。
        if !KokoroModelManifest.isComplete(in: KokoroTTSManager.modelDirectory) {
            let missing = KokoroModelManifest.corruptEntries(in: KokoroTTSManager.modelDirectory).count
            await MainActor.run {
                self.lastTTSError = missing > 0
                    ? "本地语音模型还缺 \(missing) 个文件（可能没下完）。请到「设置 → 语音」里重新下载。"
                    : "本地语音模型未下载。请到「设置 → 语音」里下载后再选本地神经 TTS。"
                self.isSpeaking = false
            }
            speakSystem(text, settings: settings)
            return
        }

        isSpeaking = true
        let voiceID = settings.ttsKokoroVoice
        let speed = Float(settings.ttsSpeed > 0 ? settings.ttsSpeed : 1.0)
        kokoroTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let engine = try KokoroTTSManager.engine()
                let (samples, rate) = try engine.generate(text: text, voiceID: voiceID, speed: speed)
                let wav = WAVWriter.wavData(samples: samples, sampleRate: rate)
                await MainActor.run {
                    // ⚠️ 取消时也要把 isSpeaking 复位 ——
                    // 原来这里直接 `return`，isSpeaking 就永远停在 true 了。
                    // 后果不是"状态显示不准"这么轻：ChatView.speakMessage 是按
                    // isSpeaking 决定"这次点击是开始还是停止"的，卡在 true 就意味着
                    // **之后每一次点朗读都只会执行"停止"**，再也读不出来。
                    guard !Task.isCancelled else {
                        self.isSpeaking = false
                        return
                    }
                    self.lastTTSError = nil
                    self.configurePlaybackSession()
                    self.playWAVData(wav)
                }
            } catch is CancellationError {
                await MainActor.run { self.isSpeaking = false }
            } catch {
                // 引擎失败（内存不足等）回退系统 TTS
                await MainActor.run {
                    self.lastTTSError = "Kokoro 引擎错误: \(error.localizedDescription)"
                    self.isSpeaking = false
                    self.speakSystem(text, settings: settings)
                }
            }
        }
    }

    // MARK: 本地神经 TTS（CosyVoice3，MLX/Metal）

    /// 与 `speakKokoro` 同构的三段式：先判可行性 → 再合成 → 最后播放。
    ///
    /// 与 Kokoro 那一路最大的区别是**失败原因必须说清楚**：CosyVoice3 有两类
    /// Kokoro 没有的失败 —— 设备内存不够（MLX 模型常驻 1~1.5GB）、以及模型没下完。
    /// 这两件事都不能靠"回退系统语音"糊过去，否则用户会以为"选了高音质、听起来还是系统音"，
    /// 而真实原因是白下了 740MB 或者机器根本跑不动。
    private func speakCosyVoice(_ text: String, settings: ModelSettings) async {
        guard !text.isEmpty else { return }

        // 设备能力：不满足就直说，不静默回退
        let verdict = LocalVoiceCapability.verdict(for: .cosyVoice)
        if case .unsupported(let why) = verdict {
            await MainActor.run {
                self.lastTTSError = why
                self.isSpeaking = false
                self.lastDiagnostic = "没走到合成：设备能力检查未通过 —— \(why)"
            }
            speakSystem(text, settings: settings)
            return
        }

        let missing = CosyVoiceTTSManager.missingFiles()
        if !missing.isEmpty {
            let names = missing.prefix(5).map(\.remotePath).joined(separator: "、")
            await MainActor.run {
                self.lastTTSError = "CosyVoice3 模型还没下完（缺 \(missing.count) 个文件）。"
                    + "请到「设置 → 语音」里下载，约 740MB。"
                self.isSpeaking = false
                self.lastDiagnostic = "没走到合成：缺 \(missing.count) 个文件 —— \(names)"
            }
            speakSystem(text, settings: settings)
            return
        }

        isSpeaking = true

        // 音色克隆：有参考音频就带上。
        // 读失败（文件被清理掉、格式损坏）**不当作致命错误** —— 退回模型自带音色仍然能出声，
        // 只是音色不是用户想要的；这种情况值得在上面的 lastTTSError 里留一句提示。
        var reference: (samples: [Float], rate: Int)?
        do {
            if let loaded = try CosyVoiceVoiceStore.shared.loadReferenceSamples() {
                reference = (loaded.0, loaded.1)
            }
        } catch {
            await MainActor.run {
                self.lastTTSError = "参考音频读取失败，这次会用模型自带音色朗读：\(error.localizedDescription)"
            }
        }

        // CosyVoice3 的合成接口没有语速参数（上游是把语速编进提示文本的），
        // 所以这里不传——留个死变量只会让人以为语速对它是生效的。
        kokoroTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                let samples = try await CosyVoiceTTSManager.shared.synthesize(
                    text: text,
                    language: Self.cosyVoiceLanguage(for: settings),
                    referenceAudio: reference?.samples,
                    referenceSampleRate: reference?.rate ?? 24000)
                guard !Task.isCancelled else {
                    await MainActor.run { self.isSpeaking = false }
                    return
                }
                let wav = WAVWriter.wavData(samples: samples, sampleRate: 24000)
                let stats = Self.stats(samples, sampleRate: 24000)
                await MainActor.run {
                    self.lastTTSError = nil
                    self.configurePlaybackSession()
                    // 峰值这一步是分水岭：它把「模型返回静音」与「播放没出声」分开。
                    // 没有它，两种原因在界面上完全一样。
                    self.lastDiagnostic = stats.isSilent
                        ? "CosyVoice3 跑通了但**输出是静音**：\(stats.text)。这属于模型/权重问题，不是播放问题。"
                        : "CosyVoice3 合成成功：\(stats.text) · WAV \(wav.count) 字节"
                    self.playWAVData(wav)
                }
            } catch {
                await MainActor.run {
                    self.lastTTSError = "CosyVoice3 合成失败：\(error.localizedDescription)"
                    self.isSpeaking = false
                    self.lastDiagnostic = "合成阶段抛错：\(error.localizedDescription)"
                    self.speakSystem(text, settings: settings)
                }
            }
        }
    }

    /// 语言标识。CosyVoice3 的提示文本里用**英文语言名**（`chinese` / `english`），
    /// 不是 `zh-CN` 这类代码 —— 传错会得到英文腔调念中文的结果。
    nonisolated static func cosyVoiceLanguage(for settings: ModelSettings) -> String {
        settings.language == "en" ? "english" : "chinese"
    }

    /// 配置音频会话为 Playback 类别（播放 TTS 时需要，静音开关下也有声音）。
    ///
    /// ⚠️ 这两个调用**都可能失败**，而原来是 `try?` 全部吞掉 —— 于是
    /// 「音频会话压根没激活成功」这种"整个 App 都发不出声"的原因，
    /// 在现场留不下任何痕迹：用户报没声音，代码里查不到任何异常。
    /// 现在把失败原因返回给调用方记进诊断。
    ///
    /// 返回 nil 表示成功，否则是失败原因。
    @discardableResult
    private func configurePlaybackSession() -> String? {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
        } catch {
            return "设置音频类别 .playback 失败：\(error.localizedDescription)"
        }
        do {
            try session.setActive(true)
        } catch {
            return "激活音频会话失败：\(error.localizedDescription)"
        }
        return nil
    }

    private func playWAVData(_ data: Data) {
        // 会话出错**不直接放弃**：有些情况只是重复激活会报错，路由其实可用。
        // 但要把它记下来 —— 这是"没声音"最隐蔽的一种原因。
        let sessionError = configurePlaybackSession()
        if let sessionError {
            lastDiagnostic = (lastDiagnostic ?? "") + " → ⚠️ \(sessionError)"
        }
        guard let player = try? AVAudioPlayer(data: data) else {
            // 数据本身放不了（格式/采样率不被接受）。**必须说出来** ——
            // 原来这里只是把 isSpeaking 置回 false，用户看到的是"点了没反应"，
            // 而没有任何线索指向"合成出来的音频有问题"。
            //
            // ⚠️ 这里原本**只写了"已回退系统 TTS"却没真的回退**：置完 isSpeaking
            // 就 return 了。于是用户的体验是「既没有本地声、也没有系统声」——
            // 报错文案在撒谎，而真正该响的那条退路没走。
            // 现在补上真正的 speakSystem 调用。
            lastTTSError = "本地语音合成成功，但音频无法播放（WAV 数据不被系统接受）。已回退系统 TTS。"
            lastDiagnostic = (lastDiagnostic ?? "")
                + " → 但系统拒绝了这段 WAV（AVAudioPlayer 初始化失败），已回退系统语音"
            isSpeaking = false
            if !lastSpokenText.isEmpty {
                speakSystem(lastSpokenText, settings: SettingsStorage.shared.settings)
            }
            return
        }
        audioPlayer = player
        player.delegate = self
        // ⚠️ `prepareToPlay()` 与 `play()` **都返回 Bool，失败时是 false**，
        // 而原来的代码把返回值直接丢掉了 —— 于是"播放失败"和"正在播放"在界面上
        // 完全一样（isSpeaking 都停在 true）。这是用户报的"切了本地 TTS 放不出声"的
        // 直接原因之一：没声音、但按钮显示正在读，而且再点一次会被当成"停止"，
        // 于是**永远起不来**（ChatView.speakMessage 是按 isSpeaking 判断的）。
        let prepared = player.prepareToPlay()
        let started = prepared && player.play()
        guard started else {
            lastTTSError = "播放失败：音频会话可能被其他 App 占用，或当前音频路由不可用。已回退系统 TTS。"
            lastDiagnostic = (lastDiagnostic ?? "")
                + " → 播放启动失败（prepareToPlay=\(prepared)），已回退系统语音"
            audioPlayer = nil
            isSpeaking = false
            speakSystem(lastSpokenText, settings: SettingsStorage.shared.settings)
            return
        }
        lastDiagnostic = (lastDiagnostic ?? "")
            + " → 已交给 AVAudioPlayer 播放（\(data.count) 字节）"
        isSpeaking = true
    }

    /// 最近一次要朗读的文本。播放失败回退系统 TTS 时要用它 ——
    /// 不回退的话用户就真的什么都听不到，而"朗读失败"本身应该是有声的失败。
    private var lastSpokenText = ""

    // MARK: 网络 TTS（OpenAI 兼容 /audio/speech）

    private func speakNetwork(_ text: String, settings: ModelSettings) async {
        // Provider 的选取顺序：**专用的 TTS Provider 优先**，没设才回落到当前对话的。
        //
        // 为什么要有"专用"这一个概念：原来只有"当前对话的 Provider"，
        // 于是能不能用语音取决于你对话时选的那家支不支持 `/audio/speech`。
        // 主力模型 DeepSeek 没有这个接口 —— 结果网络 TTS **静默回退成系统 TTS**，
        // 用户明明选了"网络 TTS"，听到的却是系统音色，而且界面上没有任何提示。
        // 现在可以单独指定一家支持 TTS 的（比如硅基流动的 CosyVoice2），与对话解耦。
        let dedicated = settings.ttsProviderID.isEmpty
            ? nil
            : ProviderStore.shared.providers.first { $0.id.uuidString == settings.ttsProviderID }
        let provider = dedicated ?? ProviderStore.shared.currentProvider

        guard let provider,
              provider.hasKey,
              provider.type != .claude && provider.type != .gemini, // 仅 OpenAI 兼容端点
              let url = URL(string: provider.cleanBaseURL + "/audio/speech")
        else {
            // 网络 TTS 不可用时回退系统 TTS。
            // ⚠️ 回退是必要的（不能因为没配好就一个字都不读），但**不能静默** ——
            // 用户选的是网络音色、听到的是系统音色，如果连一句提示都没有，
            // 他只会觉得"这个音色听起来不对"，而不会想到是配置问题。
            lastTTSError = settings.ttsProviderID.isEmpty
                ? "网络 TTS 不可用（当前对话的 Provider 不支持 /audio/speech），已回退系统 TTS。可在「设置 → 语音」里单独指定一家支持 TTS 的服务。"
                : "指定的 TTS 服务不可用（缺 Key 或地址不对），已回退系统 TTS。"
            speakSystem(text, settings: settings)
            return
        }

        // 「正在朗读」必须**一发起请求就为真**，不能等 HTTP 返回。
        // 调用方（ChatView.speakMessage）用 isSpeaking 判断该"停止"还是该"开始"，
        // 而网络请求可能要几百毫秒 —— 这段窗口里 isSpeaking 还是 false，于是再点一次
        // 不会停，反而又发一个请求、播第二路音频，两段朗读重叠。
        // Kokoro 那条路径本来就是这么做的（先置 true 再干活），网络这条漏了。
        isSpeaking = true

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(provider.primaryKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in provider.headers { request.setValue(v, forHTTPHeaderField: k) }

        var body: [String: Any] = [
            "model": settings.ttsModel.isEmpty ? "tts-1" : settings.ttsModel,
            "input": text,
            "voice": settings.ttsVoiceName.isEmpty ? "alloy" : settings.ttsVoiceName,
        ]
        if settings.ttsSpeed > 0 && settings.ttsSpeed != 1.0 {
            body["speed"] = settings.ttsSpeed
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                speakSystem(text, settings: settings)
                return
            }
            configurePlaybackSession()
            audioPlayer = try AVAudioPlayer(data: data)
            audioPlayer?.delegate = self
            isSpeaking = true
            audioPlayer?.play()
        } catch {
            speakSystem(text, settings: settings)
        }
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

extension TTSService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isSpeaking = false }
    }
}
