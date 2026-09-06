#ifndef KOKORO_BRIDGE_H
#define KOKORO_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 不透明句柄（内部为 sherpa-onnx 的 SherpaOnnxOfflineTts*）
typedef void * kokoro_tts_t;

// 创建离线 TTS 引擎（Kokoro）。所有路径参数为 UTF-8 C 字符串。
// lexicon / rule_fsts 支持逗号分隔多路径；失败返回 NULL。
kokoro_tts_t kokoro_tts_create(const char * model,
                                const char * voices,
                                const char * tokens,
                                const char * data_dir,
                                const char * lexicon,
                                const char * rule_fsts,
                                int32_t num_threads);

// 输出采样率（Kokoro 为 24000）
int32_t kokoro_tts_sample_rate(kokoro_tts_t tts);

// 合成语音：float 单声道样本（范围 [-1,1]），malloc 分配。
// out_n 带回样本数，out_sample_rate 带回采样率；失败返回 NULL。
float * kokoro_tts_generate(kokoro_tts_t tts,
                            const char * text,
                            int32_t sid,
                            float speed,
                            float silence_scale,
                            int32_t * out_n,
                            int32_t * out_sample_rate);

// 释放 kokoro_tts_generate 返回的缓冲
void kokoro_tts_free_audio(float * samples);

// 销毁引擎
void kokoro_tts_destroy(kokoro_tts_t tts);

#ifdef __cplusplus
}
#endif

#endif
