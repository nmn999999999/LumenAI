#ifndef LLAMA_BRIDGE_H
#define LLAMA_BRIDGE_H

#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct llama_bridge llama_bridge;

// Create a bridge instance. Returns 0 on success.
int  llama_bridge_create(llama_bridge ** out_bridge);
void llama_bridge_free(llama_bridge * b);

// Load a GGUF model. mmproj_path may be NULL or "" when the model is text-only.
// load_mode: LLAMA_LOAD_MODE_MMAP for memory-mapped I/O (reduces RAM usage),
//            LLAMA_LOAD_MODE_NONE for normal loading (faster but more RAM).
// kv_cache_quant: 1 = Q8_0 KV cache (halves KV memory, slight quality loss),
//                 0 = F16 KV cache (default).
// Returns true on success; on failure, use llama_bridge_last_error().
bool llama_bridge_load_model(llama_bridge * b,
                             const char * model_path,
                             const char * mmproj_path,
                             int n_ctx,
                             int n_gpu_layers,
                             int n_threads,
                             int load_mode,
                             int kv_cache_quant);

// Returns a UTF-8 error string (valid until the next bridge call).
const char * llama_bridge_last_error(llama_bridge * b);

// Report whether the loaded model actually went to the GPU: returns the most
// recent llama.cpp log line about offload / the Metal backend, e.g.
//   "load_tensors: offloaded 32/33 layers to GPU"
//   "load_tensors: offloaded 0/33 layers to GPU"      (纯 CPU)
//   "ggml_metal_init: found device: Apple A17 Pro GPU"
// Returns "" when there is no such line yet (model not loaded on this bridge).
// The pointer is owned by the bridge and stays valid until the next call to
// this function on the same thread.
//
// 为什么要这条：`n_gpu_layers` 只是我们**要求**的，真正跑没跑 GPU 只有 llama.cpp
// 自己知道（后端初始化可能失败并回落到 CPU 而不报错）。设置页显示这条 = 可验证。
const char * llama_bridge_backend_note(llama_bridge * b);

// Request the running chat generation to stop at the next token boundary.
// Safe to call from any thread while llama_bridge_chat() is running.
void llama_bridge_stop(llama_bridge * b);

// Report the KV-cache reuse statistics of the most recent llama_bridge_chat().
// *reused_tokens : prompt tokens served from the previous turn's KV prefix
//                  (i.e. NOT re-decoded this turn).
// *total_prompt_tokens : total prompt tokens of this turn.
// Either out pointer may be NULL. Safe to call from any thread.
void llama_bridge_last_kv_stats(llama_bridge * b,
                                int * reused_tokens,
                                int * total_prompt_tokens);

// Run one chat turn.
//   messages_json    : JSON array of {"role":"system"|"user"|"assistant"|"tool","content":"..."}
//   settings_json    : {"temp":f,"top_k":i,"top_p":f,"max_tokens":i}
//   image_paths_json : JSON array of image file paths (e.g. "[]" or ["/tmp/a.png"])
//   token_cb         : called with UTF-8 pieces as they are generated
// Returns 0 on success, nonzero on error.
int llama_bridge_chat(llama_bridge * b,
                     const char * messages_json,
                     const char * settings_json,
                     const char * image_paths_json,
                     void (* token_cb)(const char * piece, void * userdata),
                     void * userdata);

#ifdef __cplusplus
}
#endif

#endif // LLAMA_BRIDGE_H
