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

    func speak(_ text: String) {
        stop()
        let settings = SettingsStorage.shared.settings

        switch settings.ttsEngine {
        case "network":
            Task { await speakNetwork(text, settings: settings) }
        case "kokoro":
            Task { await speakKokoro(text, settings: settings) }
        default:
            speakSystem(text, settings: settings)
        }
    }

    func stop() {
        kokoroTask?.cancel()
        kokoroTask = nil
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

    private func speakKokoro(_ text: String, settings: ModelSettings) async {
        guard !text.isEmpty else { return }

        // 模型未就绪：回退系统 TTS 并提示
        guard KokoroModelManifest.isComplete(in: KokoroTTSManager.modelDirectory) else {
            try? await Task.sleep(nanoseconds: 100_000_000)
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
                    guard !Task.isCancelled else { return }
                    self.playWAVData(wav)
                }
            } catch is CancellationError {
                await MainActor.run { self.isSpeaking = false }
            } catch {
                // 引擎失败（内存不足等）回退系统 TTS
                await MainActor.run {
                    self.isSpeaking = false
                    self.speakSystem(text, settings: settings)
                }
            }
        }
    }

    private func playWAVData(_ data: Data) {
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .default)
        try? audioSession.setActive(true)
        if let player = try? AVAudioPlayer(data: data) {
            audioPlayer = player
            player.delegate = self
            isSpeaking = true
            player.play()
        } else {
            isSpeaking = false
        }
    }

    // MARK: 网络 TTS（OpenAI 兼容 /audio/speech）

    private func speakNetwork(_ text: String, settings: ModelSettings) async {
        guard let provider = ProviderStore.shared.currentProvider,
              provider.hasKey,
              provider.type != .claude && provider.type != .gemini, // 仅 OpenAI 兼容端点
              let url = URL(string: provider.cleanBaseURL + "/audio/speech")
        else {
            // 网络 TTS 不可用时回退系统 TTS
            speakSystem(text, settings: settings)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(provider.primaryKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in provider.headers { request.setValue(v, forHTTPHeaderField: k) }

        let body: [String: Any] = [
            "model": settings.ttsModel.isEmpty ? "tts-1" : settings.ttsModel,
            "input": text,
            "voice": settings.ttsVoiceName.isEmpty ? "alloy" : settings.ttsVoiceName,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                speakSystem(text, settings: settings)
                return
            }
            // 播放音频需 playback 会话类别，否则静音开关下无声
            let audioSession = AVAudioSession.sharedInstance()
            try? audioSession.setCategory(.playback, mode: .default)
            try? audioSession.setActive(true)
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
