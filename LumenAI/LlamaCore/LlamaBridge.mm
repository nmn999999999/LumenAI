// LlamaBridge.mm — self-contained llama.cpp + mtmd (multimodal) binding for LumenAI.
// Drop-in replacement for the LLM.swift engine. Verified against Qwen2.5-VL-3B.

#include "LlamaBridge.h"

#include <vector>
#include <string>
#include <cstring>
#include <random>
#include <algorithm>
#include <mutex>
#include <deque>
#include <sstream>

#include "llama.h"
#include "ggml.h"
#include "common.h"
#include "chat.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#include "nlohmann/json.hpp"

using json = nlohmann::json;

struct llama_bridge {
    struct llama_model *       model = nullptr;
    struct llama_context *     ctx   = nullptr;
    const struct llama_vocab * vocab = nullptr;
    struct mtmd_context *      mctx  = nullptr;          // null when text-only
    common_chat_templates_ptr  tmpls = nullptr;
    bool                       use_jinja = false;

    int    n_threads = 4;
    int    n_batch   = 512;
    int    n_ctx     = 2048;   // 上下文窗口（token 容量），用于 prompt 超长护栏
    int    max_tokens = 512;
    float  temp = 0.8f;
    int    top_k = 40;
    float  top_p = 0.9f;

    std::string last_error;
    bool stop = false;

    llama_batch batch = {};

    /// 上一轮 prompt 的 token 序列，用于**跨轮复用 KV cache**。
    ///
    /// 为什么需要：原来每次 `llama_bridge_chat` 开头都 `llama_memory_clear` ——
    /// 于是 agent 循环（一轮调一次）每一轮都把「system + 工具目录 + 整段历史」
    /// 从头重新编码一遍。第 N 轮要重算前 N-1 轮的全部 token，是 O(n²)，
    /// 手机上表现为"每一轮都比上一轮更慢"，长任务跑到后面几乎不可用。
    /// 有了它就能只解码"这次和上次不一样"的那一段。
    std::vector<llama_token> cached_tokens;

    // 最近一次 prompt 解码的 KV 前缀复用统计（供上层 profiling 读取）。
    // reused = 命中上一轮前缀、未重新解码的 token 数；total = 本轮 prompt token 总数。
    int last_kv_reused = 0;
    int last_kv_total  = 0;

    // 采样随机数生成器（跨 token 复用，避免每 token 重置种子导致采样可预测）
    std::mt19937 rng{std::random_device{}()};

    // llama.cpp 日志捕获（便于把失败原因带回 UI）
    std::mutex              log_mutex;
    std::deque<std::string> log_lines;
};

static void bridge_log_callback(ggml_log_level level, const char * text, void * user_data) {
    llama_bridge * b = static_cast<llama_bridge *>(user_data);
    if (!b || !text) return;
    std::lock_guard<std::mutex> lock(b->log_mutex);
    b->log_lines.push_back(std::string(text));
    while (b->log_lines.size() > 80) b->log_lines.pop_front();
}

static void set_error(llama_bridge * b, const std::string & msg) {
    if (b) b->last_error = msg;
}

// 错误信息附加最近一段 llama.cpp 日志，帮助定位失败原因
static std::string with_log(llama_bridge * b, const std::string & msg) {
    std::string full = msg;
    std::lock_guard<std::mutex> lock(b->log_mutex);
    if (!b->log_lines.empty()) {
        full += "\n--- llama 日志 ---\n";
        size_t start = b->log_lines.size() > 24 ? b->log_lines.size() - 24 : 0;
        for (size_t i = start; i < b->log_lines.size(); i++) {
            full += b->log_lines[i];
        }
    }
    return full;
}

// 拼接提示词模式：不使用模型内嵌 chat template(jinja)，直接按 "role: content" 拼接。
// 对缺少模板或模板解析异常的模型更通用，行为可控。
static std::string build_concat_prompt(const std::vector<common_chat_msg> & msgs) {
    std::ostringstream ss;
    for (const auto & m : msgs) {
        std::string role = m.role.empty() ? "user" : m.role;
        if (role == "tool") { role = "assistant"; } // 工具结果归为 assistant 上下文，使模型理解"这是补充信息"
        // 去掉内容里已有的重复前缀，避免 "user: user: xxx"
        std::string content = m.content;
        std::string prefix = role + ": ";
        if (content.rfind(prefix, 0) == 0) { content = content.substr(prefix.size()); }
        ss << role << ": " << content << "\n";
    }
    ss << "assistant:";
    return ss.str();
}

int llama_bridge_create(llama_bridge ** out_bridge) {
    *out_bridge = new llama_bridge();
    return 0;
}

void llama_bridge_free(llama_bridge * b) {
    if (!b) return;
    if (b->mctx)  mtmd_free(b->mctx);
    if (b->ctx)   {
        llama_batch_free(b->batch);
        llama_free(b->ctx);
    }
    if (b->model) llama_model_free(b->model);
    delete b;
}

bool llama_bridge_load_model(llama_bridge * b,
                             const char * model_path,
                             const char * mmproj_path,
                             int n_ctx,
                             int n_gpu_layers,
                             int n_threads,
                             int load_mode,
                             int kv_cache_quant) {
    if (!b) return false;
    b->n_threads = n_threads > 0 ? n_threads : 4;
    llama_log_set(bridge_log_callback, b);
    {
        std::lock_guard<std::mutex> lock(b->log_mutex);
        b->log_lines.clear();
    }

    struct llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = n_gpu_layers;
    mparams.load_mode = static_cast<llama_load_mode>(load_mode);
    // 记录加载参数用于调试
    {
        std::ostringstream debug;
        debug << "[Bridge] Loading model: " << model_path
              << " | n_ctx=" << n_ctx
              << " | n_gpu_layers=" << n_gpu_layers
              << " | load_mode=" << load_mode
              << " | n_threads=" << n_threads;
        std::lock_guard<std::mutex> lock(b->log_mutex);
        b->log_lines.push_back(debug.str());
    }
    b->model = llama_model_load_from_file(model_path, mparams);
    if (!b->model) {
        set_error(b, with_log(b, std::string("无法加载模型: ") + (model_path ? model_path : "")));
        return false;
    }

    struct llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx = n_ctx > 0 ? (uint32_t)n_ctx : 2048;
    b->n_ctx = (int)cparams.n_ctx;   // 记录真实窗口，供后续护栏使用
    cparams.n_threads = b->n_threads;
    cparams.n_threads_batch = b->n_threads;
    // Metal 后端上 Flash Attention 的稳定性问题：先关闭，换取可靠解码
    cparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
    // KV cache 量化：Q8_0 使 K-cache 内存减半。
    // 重要约束:llama.cpp 要求 "quantized V cache 必须 flash_attn 开启"；
    // 当前 flash_attn 已关闭,所以 V cache 必须保持 F16,只对 K cache 量化。
    // 否则启动时直接报:`llama_init_from_model: quantized V cache requires flash_attn to be enabled`
    if (kv_cache_quant) {
        cparams.type_k = GGML_TYPE_Q8_0;
        cparams.type_v = GGML_TYPE_F16;  // V cache 保持 F16(满足无 flash_attn 的约束)
    }
    b->ctx = llama_init_from_model(b->model, cparams);
    if (!b->ctx) {
        set_error(b, with_log(b, "无法初始化上下文"));
        return false;
    }
    b->vocab = llama_model_get_vocab(b->model);
    // llama.cpp 新版 (>= b4xxx) 的 llama_batch_init 分配的是固定大小数组，
    // 必须在分配时预留足够的 token 槽位（最大为整个 context），否则
    // common_batch_add 会在第二个 token 处触发 "llama_batch size exceeded" 断言崩溃。
    b->batch = llama_batch_init((int32_t)cparams.n_ctx, 0, 1);

    // chat template（拼接模式不依赖它；无模板的模型也可用，只是不参与 prompt 构造）
    b->tmpls = common_chat_templates_init(b->model, "");

    // optional multimodal projector
    if (mmproj_path && strlen(mmproj_path) > 0) {
        struct mtmd_context_params mparams2 = mtmd_context_params_default();
        mparams2.n_threads = b->n_threads;
        // mmproj 视觉编码器放 CPU，避免与主模型争抢 iPhone 有限的 GPU/统一内存
        mparams2.use_gpu   = false;
        b->mctx = mtmd_init_from_file(mmproj_path, b->model, mparams2);
        if (!b->mctx) {
            set_error(b, std::string("无法加载 mmproj: ") + mmproj_path);
            return false;
        }
        if (!mtmd_helper_model_can_chat(b->ctx, b->mctx)) {
            set_error(b, "该 mmproj 不支持对话模式");
            return false;
        }
    }
    b->last_error.clear();
    return true;
}

const char * llama_bridge_last_error(llama_bridge * b) {
    return b ? b->last_error.c_str() : "null bridge";
}

void llama_bridge_stop(llama_bridge * b) {
    if (b) b->stop = true;
}

void llama_bridge_last_kv_stats(llama_bridge * b,
                                int * reused_tokens,
                                int * total_prompt_tokens) {
    if (reused_tokens)       *reused_tokens = b ? b->last_kv_reused : 0;
    if (total_prompt_tokens) *total_prompt_tokens = b ? b->last_kv_total : 0;
}

// ---- sampling (temperature + top-k + top-p) ----
static llama_token sample_token(llama_bridge * b, float * logits) {
    const int n_vocab = llama_vocab_n_tokens(b->vocab);
    std::vector<float> scores(n_vocab);
    for (int i = 0; i < n_vocab; i++) scores[i] = logits[i];

    if (b->temp > 0.0f) {
        for (int i = 0; i < n_vocab; i++) scores[i] /= b->temp;
    }

    int top_k = b->top_k > 0 ? b->top_k : n_vocab;
    std::vector<int> idx(n_vocab);
    for (int i = 0; i < n_vocab; i++) idx[i] = i;
    std::partial_sort(idx.begin(), idx.begin() + std::min(top_k, n_vocab), idx.end(),
        [&](int a, int c) { return scores[a] > scores[c]; });

    float max_l = scores[idx[0]];
    float sum = 0.0f;
    std::vector<float> probs(top_k);
    for (int i = 0; i < top_k; i++) {
        probs[i] = expf(scores[idx[i]] - max_l);
        sum += probs[i];
    }
    if (sum <= 0.0f) return (llama_token)idx[0];

    // top-p nucleus
    float cum = 0.0f;
    int chosen = 0;
    std::uniform_real_distribution<float> dist(0.0f, 1.0f);
    float r = dist(b->rng) * sum;
    for (int i = 0; i < top_k; i++) {
        cum += probs[i];
        if (cum >= r * b->top_p) { chosen = i; break; }
        chosen = i;
    }
    return (llama_token)idx[chosen];
}

// ---- text-only path (no mmproj): tokenize + decode + generate ----
// 返回 llama_decode 的返回码（0 = 成功）
static int eval_tokens(llama_bridge * b, const std::vector<llama_token> & toks, bool logits_last) {
    // 防御：batch 容量 = n_ctx，绝不允许超出，否则 common_batch_add 触发越界断言/abort。
    const size_t cap = (b->n_ctx > 0) ? (size_t)b->n_ctx : toks.size();
    const size_t n   = std::min(toks.size(), cap);
    common_batch_clear(b->batch);
    for (size_t i = 0; i < n; i++) {
        common_batch_add(b->batch, toks[i], (llama_pos)i, {0}, logits_last && (i + 1 == n));
    }
    return llama_decode(b->ctx, b->batch);
}

/// 与 `eval_tokens` 相同，但只解码 `toks[start_idx...]`，并把它们的**绝对位置**
/// 从 `start_pos` 开始编号。
///
/// 为什么不复用 `eval_tokens`：那个函数把位置硬编码成从 0 开始（`(llama_pos)i`），
/// 只能用于"从头解码整个 prompt"。前缀复用必须能指定"从第几个位置接着写"，
/// 否则新解码的 token 位置会和 KV 里已复用的部分重叠 → 报
/// "inconsistent sequence positions"（这正是原来那句注释里担心的失败）。
static int eval_tokens_from(llama_bridge * b, const std::vector<llama_token> & toks,
                            size_t start_idx, llama_pos start_pos) {
    common_batch_clear(b->batch);
    size_t n = 0;
    for (size_t i = start_idx; i < toks.size(); i++) {
        common_batch_add(b->batch, toks[i], start_pos + (llama_pos)n, {0},
                         i + 1 == toks.size());
        n++;
    }
    if (n == 0) return 0;
    return llama_decode(b->ctx, b->batch);
}

static int generate(llama_bridge * b, int n_past_start, void (*cb)(const char *, void *), void * ud) {
    int n_past = n_past_start;
    int max_tokens = b->max_tokens > 0 ? b->max_tokens : 512;
    std::vector<llama_token> gen;
    for (int i = 0; i < max_tokens; i++) {
        if (b->stop) break; // 用户点击停止
        // 上下文护栏（v0.3.43）：预留 8 token 余量，接近 n_ctx 上限时提前收尾。
        // 否则生成阶段 n_past 越界 → llama_decode 返回非零 → "生成解码失败"。
        // Agent 模式注入超长工具目录后（小模型尤甚），提示词几乎占满上下文，
        // 生成一两个 token 就溢出 —— 这是 Qwen3 小模型 Agent 模式解码失败的根因。
        if (b->n_ctx > 0 && n_past >= b->n_ctx - 8) break;
        float * logits = llama_get_logits(b->ctx);
        llama_token token = sample_token(b, logits);
        if (llama_vocab_is_eog(b->vocab, token)) break;
        std::string piece = common_token_to_piece(b->ctx, token);
        if (!piece.empty() && cb) {
            // common_token_to_piece 返回的已是合法 UTF-8，直接转发；
            // 非法字节由 Swift 端 String(cString:encoding:) 兜底处理，不在此破坏多字节字符
            cb(piece.c_str(), ud);
        }
        common_batch_clear(b->batch);
        common_batch_add(b->batch, token, n_past, {0}, true);
        int rc = llama_decode(b->ctx, b->batch);
        if (rc != 0) {
            std::string hint = "生成解码失败 (ret=" + std::to_string(rc) + ", n_past=" + std::to_string(n_past) + ")";
            // 检测 Metal / GPU 统一内存不足，给出可操作建议
            {
                std::lock_guard<std::mutex> lock(b->log_mutex);
                // 记录更多调试信息
                b->log_lines.push_back("[Bridge] decode failed at n_past=" + std::to_string(n_past) + " token=" + std::to_string(token));
                for (const auto & line : b->log_lines) {
                    if (line.find("Insufficient Memory") != std::string::npos ||
                        line.find("ggml_metal") != std::string::npos ||
                        line.find("Metal") != std::string::npos) {
                        hint += "\n\n提示：Metal GPU 显存/统一内存不足。\n建议：到「设置」把「GPU 层数」改为 0（纯 CPU），或把「上下文长度」降到 2048 及以下，然后到「模型」页重新加载模型。";
                        break;
                    }
                }
            }
            set_error(b, with_log(b, hint));
            return 1;
        }
        n_past++;
    }
    return 0;
}

// ---- main chat entry ----
int llama_bridge_chat(llama_bridge * b,
                      const char * messages_json,
                      const char * settings_json,
                      const char * image_paths_json,
                      void (* token_cb)(const char * piece, void * userdata),
                      void * userdata) {
    if (!b || !b->model || !b->ctx) {
        set_error(b, "模型尚未加载");
        return 1;
    }
    b->stop = false; // 新一轮生成，重置停止标志
    // ⚠️ 这里**不再无条件清空 KV cache**。
    //
    // 原来清空的理由是"桥接无状态、每轮重编码完整历史，位置才对得上"——
    // 那个理由是在"每轮全量重编码"的前提下成立的。现在下半部分会算出
    // 与上一轮的**最长公共前缀**并只补解码增量，所以这里的清空是多余的，
    // 而且正是它让长任务每一轮都要重算全部历史（O(n²)）。
    // 清理动作改由各路径自己决定：多模态一律清空（图像块使 token 流不可简单比较），
    // 纯文本按前缀复用，且带"对不上就整体重来"的安全阀。
    if (!b->tmpls) {
        set_error(b, "chat template 未初始化");
        return 1;
    }

    // settings
    try {
        json s = json::parse(std::string(settings_json ? settings_json : "{}"));
        if (s.contains("temp"))      b->temp = s["temp"].get<float>();
        if (s.contains("top_k"))     b->top_k = s["top_k"].get<int>();
        if (s.contains("top_p"))     b->top_p = s["top_p"].get<float>();
        if (s.contains("max_tokens")) b->max_tokens = s["max_tokens"].get<int>();
    } catch (...) {}

    // messages
    std::vector<common_chat_msg> all;
    try {
        json m = json::parse(std::string(messages_json ? messages_json : "[]"));
        for (auto & e : m) {
            common_chat_msg cm;
            cm.role    = e.value("role", std::string("user"));
            cm.content = e.value("content", std::string(""));
            all.push_back(cm);
        }
    } catch (...) {
        set_error(b, "messages_json 解析失败");
        return 2;
    }
    if (all.empty()) {
        set_error(b, "messages 为空");
        return 2;
    }

    // images
    std::vector<std::string> img_paths;
    try {
        json p = json::parse(std::string(image_paths_json ? image_paths_json : "[]"));
        for (auto & e : p) img_paths.push_back(e.get<std::string>());
    } catch (...) {}

    // history 仅用于决定是否在 tokenize 时加 BOS；模板格式化使用完整消息列表 all
    std::vector<common_chat_msg> history(all.begin(), all.end() - 1);
    bool add_bos = history.empty();

    std::string marker;
    if (b->mctx) marker = mtmd_get_marker(b->mctx);

    // inject media markers into the new user message
    if (b->mctx && !img_paths.empty()) {
        std::string injected;
        for (size_t i = 0; i < img_paths.size(); i++) injected += marker + "\n";
        all.back().content = injected + all.back().content;
    }

    // 优先用模型自带的 chat template（效果最好）；无模板模型才回退到拼接模式
    // 注意：必须用 common_chat_templates_apply 格式化【完整】历史，
    // common_chat_format_single 只返回增量 diff（依赖 KV cache 保留历史），
    // 与本实现的每轮 KV 清理策略不兼容，会导致多轮上下文丢失。
    std::string formatted;
    if (b->tmpls) {
        common_chat_templates_inputs inputs;
        inputs.messages = all;
        inputs.add_generation_prompt = true;
        inputs.use_jinja = b->use_jinja;
        formatted = common_chat_templates_apply(b->tmpls.get(), inputs).prompt;
    } else {
        formatted = build_concat_prompt(all);
    }

    // ----- multimodal path -----
    if (b->mctx) {
        // 多模态一律全量重来：图像会被 mtmd 变成若干个 chunk，
        // 其 token 流与上一轮不能按"逐 token 比较"来求公共前缀，
        // 硬做前缀复用会把图像特征的位置算错。这里求稳。
        llama_memory_clear(llama_get_memory(b->ctx), true);
        b->cached_tokens.clear();
        b->last_kv_reused = 0;   // 多模态全量重编码：无前缀复用
        b->last_kv_total  = 0;
        mtmd::bitmaps bitmaps;
        for (auto & p : img_paths) {
            auto res = mtmd_helper_bitmap_init_from_file(b->mctx, p.c_str(), false);
            if (res.bitmap) bitmaps.entries.emplace_back(res.bitmap);
        }
        auto bitmap_ptrs = bitmaps.c_ptr();

        mtmd_input_text text;
        text.text          = formatted.data();
        text.text_len      = formatted.size();
        text.add_special   = add_bos;
        text.parse_special = true;

        mtmd::input_chunks chunks(mtmd_input_chunks_init());
        int32_t res = mtmd_tokenize(b->mctx, chunks.ptr.get(), &text,
                                    bitmap_ptrs.data(), bitmap_ptrs.size());
        if (res != 0) {
            set_error(b, with_log(b, std::string("mtmd_tokenize 失败, res=") + std::to_string(res)));
            return 3;
        }

        int n_past = 0;
        size_t n_chunks = mtmd_input_chunks_size(chunks.ptr.get());
        mtmd::batch_ptr mbatch;
        for (size_t i = 0; i < n_chunks; i++) {
            auto chunk = mtmd_input_chunks_get(chunks.ptr.get(), i);
            auto ctype = mtmd_input_chunk_get_type(chunk);
            if (ctype == MTMD_INPUT_CHUNK_TYPE_TEXT) {
                llama_pos new_n_past = n_past;
                res = mtmd_helper_eval_chunk_single(b->mctx, b->ctx, chunk, n_past, 0,
                                                    b->n_batch, i == n_chunks - 1, &new_n_past);
                if (res != 0) { set_error(b, with_log(b, "文本块解码失败 (ret=" + std::to_string(res) + ")")); return 4; }
                n_past = new_n_past;
            } else {
                float * embd = nullptr;
                if (mbatch) embd = mtmd_batch_get_output_embd(mbatch.get(), chunk);
                if (!embd) {
                    mbatch.reset(mtmd_batch_init(b->mctx));
                    int r = mtmd_batch_add_chunk(mbatch.get(), chunk);
                    if (r != 0) { set_error(b, "batch add 失败"); return 4; }
                    for (size_t j = i + 1; j < n_chunks; j++) {
                        auto nx = mtmd_input_chunks_get(chunks.ptr.get(), j);
                        if (mtmd_input_chunk_get_type(nx) == MTMD_INPUT_CHUNK_TYPE_TEXT) break;
                        if (mtmd_batch_add_chunk(mbatch.get(), nx) != 0) break;
                    }
                    if (mtmd_batch_encode(mbatch.get()) != 0) { set_error(b, "batch encode 失败"); return 4; }
                    embd = mtmd_batch_get_output_embd(mbatch.get(), chunk);
                }
                if (!embd) { set_error(b, "无法获取图像 embedding"); return 4; }
                llama_pos new_n_past = n_past;
                res = mtmd_helper_decode_image_chunk(b->mctx, b->ctx, chunk, embd, n_past, 0,
                                                     b->n_batch, &new_n_past, nullptr, nullptr);
                if (res != 0) { set_error(b, "图像块解码失败"); return 4; }
                n_past = new_n_past;
            }
        }
        int gret = generate(b, n_past, token_cb, userdata);
        if (gret != 0) return 6;
        return 0;
    }

    // ----- text-only path -----
    std::vector<llama_token> toks = common_tokenize(b->ctx, formatted, add_bos, true);
    // 护栏：prompt 的 token 数不得超过上下文窗口，否则 common_batch_add 越界触发 abort。
    // 超出时丢弃最旧的 token、保留最近的上下文。
    // 注意：这里是"**全量重编码 + 前缀复用**"两条路：前缀能复用时不会重编码历史，
    // 只有前缀对不上（换会话 / 换工具集）或被护栏截断时才从头重算。
    if (b->n_ctx > 0 && (int)toks.size() > b->n_ctx) {
        toks.erase(toks.begin(), toks.end() - b->n_ctx);
    }
    // ── 跨轮复用 KV cache（前缀缓存）──
    //
    // 做法：求"这次 prompt"与"上次 prompt"的最长公共前缀 L，删掉 KV 里 L 之后的部分，
    // 只解码 `toks[L...]`（位置从 L 开始编号）。system 提示词 + 工具目录 + 已经
    // 对话过的历史都属于公共前缀 —— 它们**一次都不会被重算**。
    //
    // ── STATIC PREFIX / DYNAMIC CONTEXT 的布局约定（阶段 10）──
    // 上层（AgentService.withToolInstructions）保证 prompt 的时间序布局为：
    //   [STATIC] system（身份 / agent 协议 / 工具目录）→ [DYNAMIC] user → assistant/tool 历史
    // 其中 STATIC 部分在一次 run 内保持逐字不变：
    //   · 工具目录由 ToolRouter 选出，而选择只依赖"本轮用户请求 + 已用工具"；
    //     已用工具必然是**已被暴露过**的工具（模型只能调用它看到的），
    //     因此选择在 run 内自然收敛、不再变化 —— 不会因为"多调了一个工具"而每轮翻新前缀。
    //   · 环境段只读设置真源，run 内不变。
    // 结果：整个 STATIC PREFIX 天然落在公共前缀里，工具集变化不会让前缀整体失效。
    // 唯一会改变 STATIC 的时机是 create_plugin 在本轮装出新工具（那本来就该刷新目录），
    // 属于一次性失效，符合预期。
    // 会话隔离仍由每个 session 独立的 bridge 实例保证（cached_tokens 是实例字段）。
    size_t lcp = 0;
    {
        llama_memory_t mem = llama_get_memory(b->ctx);
        const llama_pos kv_len = llama_memory_seq_pos_max(mem, 0) + 1;
        while (lcp < b->cached_tokens.size() && lcp < toks.size()
               && b->cached_tokens[lcp] == toks[lcp]) {
            lcp++;
        }
        // ── 安全阀 ──
        // 两个必须挡住的情况：
        //   1. KV 里实际保存的位置数比 L 还少（比如上一轮生成时被 n_ctx 护栏截断过、
        //      或者中途 stop 掉了）—— 那时"复用的前缀"其实并不存在，接着写会错位；
        //   2. 前缀算出来是 0（这一轮的开头就变了，例如走的是不同的人格/工具集）。
        // 两者都退化成**全量重编码**，也就是改动前的行为。
        // 这个安全阀是刻意的：前缀复用如果出错，表现会是"回答变得莫名其妙"，
        // 而不是报错 —— 那种错极难归因。宁可慢，也绝不能错位。
        if (kv_len <= 0 || (llama_pos)lcp > kv_len) lcp = 0;
        if (lcp > 0) {
            llama_memory_seq_rm(mem, 0, (llama_pos)lcp, -1);
        } else {
            llama_memory_clear(mem, true);
        }
        // profiling：记录本轮前缀复用情况（即使解码失败也如实反映"本来能复用多少"）
        b->last_kv_reused = (int)lcp;
        b->last_kv_total  = (int)toks.size();
    }
    // ⚠️ 必须加锁：log_lines 会被另一个线程（取日志的 UI 路径）读取，
    // 裸 push_back 是数据竞争（本工程用 ThreadSanitizer 跑过，不留这种）。
    {
        std::lock_guard<std::mutex> lock(b->log_mutex);
        if (lcp > 0) {
            b->log_lines.push_back("[Bridge] KV 前缀复用 " + std::to_string(lcp) + "/"
                                   + std::to_string(toks.size()) + " token，只解码 "
                                   + std::to_string(toks.size() - lcp) + " 个");
        } else {
            b->log_lines.push_back("[Bridge] KV 全量重编码 " + std::to_string(toks.size()) + " token");
        }
    }

    int rc = (lcp > 0) ? eval_tokens_from(b, toks, lcp, (llama_pos)lcp)
                       : eval_tokens(b, toks, true);
    if (rc != 0) {
        set_error(b, with_log(b, "prompt 解码失败 (ret=" + std::to_string(rc) + ")"));
        return 5;
    }
    // 记下这一轮的 prompt：下一轮求公共前缀要用它。
    // 注意只记 prompt、不记生成出来的 token —— 生成的正文本来就会作为 assistant
    // 消息出现在下一轮 prompt 里，公共前缀自然会延伸到那里，不需要额外维护。
    b->cached_tokens = toks;
    int gret = generate(b, (int)toks.size(), token_cb, userdata);
    if (gret != 0) return 6;
    return 0;
}
