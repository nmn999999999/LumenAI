import Foundation

/// 网络 TTS 的快速预设。
///
/// 为什么需要它：网络 TTS 要同时填对**三样东西** —— 服务地址（在哪家）、模型名、音色名，
/// 而三样都是各家自己的字符串（`FunAudioLLM/CosyVoice2-0.5B`、`alex`…）。
/// 打错一个字符就是一个 400，而 OpenAI 兼容端点的错误提示通常只有一句
/// "invalid request"，根本看不出是名字写错了 —— 用户会以为是功能坏了。
///
/// 表里的名字都是各家文档里的**原文**。国内能直连的排在前面。
struct TTSPreset: Identifiable, Sendable {
    let id: String
    let providerHint: String   // 给用户看的"这是哪家"
    let label: String          // 音色名（人话）
    let baseURLHint: String    // 用来匹配用户已配好的 Provider（按地址片段）
    let model: String
    let voice: String
}

enum TTSPresets {
    static let all: [TTSPreset] = [
        // ── 硅基流动：国内直连，CosyVoice2 是目前最好用的中文神经 TTS 之一 ──
        TTSPreset(id: "sf-alex", providerHint: "硅基流动", label: "Alex · 中文男声",
                  baseURLHint: "siliconflow", model: "FunAudioLLM/CosyVoice2-0.5B", voice: "FunAudioLLM/CosyVoice2-0.5B:alex"),
        TTSPreset(id: "sf-diana", providerHint: "硅基流动", label: "Diana · 中文女声",
                  baseURLHint: "siliconflow", model: "FunAudioLLM/CosyVoice2-0.5B", voice: "FunAudioLLM/CosyVoice2-0.5B:diana"),
        TTSPreset(id: "sf-benjamin", providerHint: "硅基流动", label: "Benjamin · 中文男声",
                  baseURLHint: "siliconflow", model: "FunAudioLLM/CosyVoice2-0.5B", voice: "FunAudioLLM/CosyVoice2-0.5B:benjamin"),
        TTSPreset(id: "sf-charles", providerHint: "硅基流动", label: "Charles · 中文男声",
                  baseURLHint: "siliconflow", model: "FunAudioLLM/CosyVoice2-0.5B", voice: "FunAudioLLM/CosyVoice2-0.5B:charles"),

        // ── 阿里云 DashScope（百炼）──
        TTSPreset(id: "dash-longxiaochun", providerHint: "阿里云百炼", label: "龙小淳 · 中文女声",
                  baseURLHint: "dashscope", model: "cosyvoice-v1", voice: "longxiaochun"),
        TTSPreset(id: "dash-longxiaoxia", providerHint: "阿里云百炼", label: "龙小夏 · 中文女声",
                  baseURLHint: "dashscope", model: "cosyvoice-v1", voice: "longxiaoxia"),
        TTSPreset(id: "dash-longlaoda", providerHint: "阿里云百炼", label: "龙老铁 · 中文男声",
                  baseURLHint: "dashscope", model: "cosyvoice-v1", voice: "longlaotie"),

        // ── OpenAI 兼容的标准音色（任何支持 /audio/speech 的服务都能用）──
        TTSPreset(id: "openai-alloy", providerHint: "OpenAI 兼容", label: "Alloy（标准音色）",
                  baseURLHint: "", model: "tts-1", voice: "alloy"),
        TTSPreset(id: "openai-nova", providerHint: "OpenAI 兼容", label: "Nova（标准音色）",
                  baseURLHint: "", model: "tts-1", voice: "nova"),
        TTSPreset(id: "openai-echo", providerHint: "OpenAI 兼容", label: "Echo（标准音色）",
                  baseURLHint: "", model: "tts-1", voice: "echo"),
    ]
}
