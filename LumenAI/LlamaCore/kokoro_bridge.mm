#import "kokoro_bridge.h"

#include <string.h>
#include <stdlib.h>

#import <sherpa-onnx/c-api/c-api.h>

kokoro_tts_t kokoro_tts_create(const char * model,
                                const char * voices,
                                const char * tokens,
                                const char * data_dir,
                                const char * lexicon,
                                const char * rule_fsts,
                                int32_t num_threads) {
    SherpaOnnxOfflineTtsConfig config;
    memset(&config, 0, sizeof(config));

    config.model.kokoro.model = model;
    config.model.kokoro.voices = voices;
    config.model.kokoro.tokens = tokens;
    config.model.kokoro.data_dir = data_dir;
    config.model.kokoro.lexicon = lexicon;
    config.model.num_threads = num_threads;
    config.model.debug = 0;
    config.model.provider = "cpu";
    config.rule_fsts = rule_fsts;
    config.max_num_sentences = 1;
    config.silence_scale = 0.2f;

    const SherpaOnnxOfflineTts * tts = SherpaOnnxCreateOfflineTts(&config);
    // 去 const：Swift 侧只作为不透明句柄传递
    return (kokoro_tts_t)(uintptr_t)tts;
}

int32_t kokoro_tts_sample_rate(kokoro_tts_t tts) {
    if (!tts) { return 24000; }
    return SherpaOnnxOfflineTtsSampleRate((const SherpaOnnxOfflineTts *)tts);
}

float * kokoro_tts_generate(kokoro_tts_t tts,
                            const char * text,
                            int32_t sid,
                            float speed,
                            float silence_scale,
                            int32_t * out_n,
                            int32_t * out_sample_rate) {
    if (!tts || !text || text[0] == '\0') { return NULL; }

    SherpaOnnxGenerationConfig gen;
    memset(&gen, 0, sizeof(gen));
    gen.sid = sid;
    gen.speed = speed;
    gen.silence_scale = silence_scale;

    const SherpaOnnxGeneratedAudio * audio =
        SherpaOnnxOfflineTtsGenerateWithConfig(
            (const SherpaOnnxOfflineTts *)tts, text, &gen, NULL, NULL);
    if (!audio || !audio->samples || audio->n <= 0) {
        if (audio) { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio); }
        return NULL;
    }

    // 拷贝一份由调用方拥有的缓冲（原结构体由 sherpa 管理）
    size_t bytes = (size_t)audio->n * sizeof(float);
    float * out = (float *)malloc(bytes);
    if (!out) {
        SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
        return NULL;
    }
    memcpy(out, audio->samples, bytes);
    if (out_n) { *out_n = audio->n; }
    if (out_sample_rate) { *out_sample_rate = audio->sample_rate; }
    SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio);
    return out;
}

void kokoro_tts_free_audio(float * samples) {
    free(samples);
}

void kokoro_tts_destroy(kokoro_tts_t tts) {
    if (tts) {
        SherpaOnnxDestroyOfflineTts((const SherpaOnnxOfflineTts *)tts);
    }
}
