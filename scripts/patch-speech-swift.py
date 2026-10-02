#!/usr/bin/env python3
"""让 speech-swift v0.0.28 接受 4-bit 的 CosyVoice3 模型包。

上游只放行 8-bit 与 bf16 两种权重布局：`CosyVoiceTTSModel.fromPretrained`
读 `config.json` 的 `quantization.bits` 时，非 8/16 直接抛错
("must be 8-bit quantized or 16-bit/bf16 plain Linear.")。但 MLX 的
`QuantizedLinear` 本身原生支持 4-bit，这条限制只是判断写死了。

而且 4-bit 包的 `config.json` 只声明了 LLM 的 `quantization`，
**没有 `dit_quantization` 块** —— 于是 DiT 会退回 8-bit 默认值去校验
4-bit 张量，形状检查同样过不去（实测 `flow.safetensors` 里 158 个
`.scales` 全是 4-bit）。

本脚本做两件事：
  1. 放行 4-bit（LLM 与 DiT 两处 switch，以及权重加载里的位宽校验）。
  2. 更根本地：让加载器**从 `(weight, scales)` 的形状反推真实位宽**，
     使 `config.json` 的声明值不再是唯一依据 —— 这样即便上游以后
     再漏写某个块的声明，也不会误判。

脚本幂等：已打过补丁则直接跳过。SPM checkout 默认只读，会先补写权限。

用法:
    python3 scripts/patch-speech-swift.py          # 自动搜索 checkout
    python3 scripts/patch-speech-swift.py <dir>    # 指定 checkout 根目录
"""

import glob
import io
import os
import sys

APPLIED_MARK = "resolveQuantizationBits"

# ── WeightLoading.swift ──────────────────────────────────────────────────────

WL_LLM_OLD = '''            if let scales = weights["\\(stPrefix).scales"],
               let w = weights["\\(stPrefix).weight"] {
                let bits = llmConfig.bits
                let groupSize = llmConfig.groupSize
                try validate8BitQuantizationLayout(
                    weight: w, scales: scales, bits: bits, groupSize: groupSize)'''

WL_LLM_NEW = '''            if let scales = weights["\\(stPrefix).scales"],
               let w = weights["\\(stPrefix).weight"] {
                let groupSize = llmConfig.groupSize
                let bits = try resolveQuantizationBits(
                    weight: w, scales: scales,
                    groupSize: groupSize, declared: llmConfig.bits)'''

WL_DIT_OLD = '''            if let scales = weights["\\(stPrefix).scales"],
               let w = weights["\\(stPrefix).weight"] {
                let bits = ditConfig.bits
                let groupSize = ditConfig.groupSize
                try validate8BitQuantizationLayout(
                    weight: w, scales: scales, bits: bits, groupSize: groupSize)'''

WL_DIT_NEW = '''            if let scales = weights["\\(stPrefix).scales"],
               let w = weights["\\(stPrefix).weight"] {
                let groupSize = ditConfig.groupSize
                let bits = try resolveQuantizationBits(
                    weight: w, scales: scales,
                    groupSize: groupSize, declared: ditConfig.bits)'''

WL_TAIL_MARKER = "    /// Validate MLX's packed 8-bit QuantizedLinear layout."

WL_TAIL_NEW = '''    /// Resolve the packing bit width for a quantized `(weight, scales)` pair.
    ///
    /// The width declared in `config.json` is **not** trustworthy on its own:
    /// the 4-bit bundle ships a `quantization` block for the LLM but omits
    /// `dit_quantization` entirely, so the DiT would otherwise be dispatched
    /// with the 8-bit default while its tensors are 4-bit packed. The tensor
    /// shapes are the ground truth, so derive the width from them.
    ///
    /// MLX packs `32 / bits` values into one `uint32` word and groups every
    /// `group_size` input features:
    ///   packedCols = inFeatures / elementsPerWord
    ///   numGroups  = inFeatures / groupSize
    /// hence `elementsPerWord = numGroups * groupSize / packedCols` and
    /// `bits = 32 / elementsPerWord`.
    static func resolveQuantizationBits(
        weight: MLXArray,
        scales: MLXArray,
        groupSize: Int,
        declared: Int
    ) throws -> Int {
        guard weight.ndim == 2, scales.ndim == 2 else {
            throw CosyVoiceTTSError.modelLoadFailed(
                "CosyVoice quantized weights must be rank-2 MLX QuantizedLinear tensors.")
        }
        let packedCols = weight.dim(1)
        let numGroups = scales.dim(1)
        guard packedCols > 0, numGroups > 0, groupSize > 0 else {
            throw CosyVoiceTTSError.modelLoadFailed(
                "CosyVoice quantized weights have an invalid packed shape.")
        }
        let inFeatures = numGroups * groupSize
        guard inFeatures % packedCols == 0 else {
            throw CosyVoiceTTSError.modelLoadFailed(
                "CosyVoice quantized weights are not packed against group_size \\(groupSize).")
        }
        let elementsPerWord = inFeatures / packedCols
        guard elementsPerWord > 0, 32 % elementsPerWord == 0 else {
            throw CosyVoiceTTSError.modelLoadFailed(
                "CosyVoice quantized weights are not a valid MLX packed layout.")
        }
        let inferred = 32 / elementsPerWord
        guard inferred == 4 || inferred == 8 else {
            throw CosyVoiceTTSError.modelLoadFailed(
                "CosyVoice packed quantized weights must be 4-bit or 8-bit; "
                + "16-bit/bf16 bundles must not include .scales (found \\(inferred)-bit).")
        }
        if inferred != declared {
            print("  NOTE: bundle declares \\(declared)-bit but the packed tensors are "
                  + "\\(inferred)-bit; using the tensor layout.")
        }
        return inferred
    }
}
'''

# ── CosyVoiceTTS.swift ───────────────────────────────────────────────────────

CV_LLM_OLD = '''                    switch bits {
                    case 8:
                        config.llm.bits = bits
                        print("  Bundle quantization (LLM): \\(config.llm.bits)-bit (group_size \\(config.llm.groupSize))")
                    case 16:
                        config.llm.bits = bits
                        print("  Bundle precision (LLM): 16-bit (plain Linear; no .scales)")
                    default:
                        throw CosyVoiceTTSError.modelLoadFailed(
                            "CosyVoice LLM bundles must be 8-bit quantized or 16-bit/bf16 plain Linear.")
                    }'''

CV_LLM_NEW = '''                    switch bits {
                    case 4, 8:
                        config.llm.bits = bits
                        print("  Bundle quantization (LLM): \\(config.llm.bits)-bit (group_size \\(config.llm.groupSize))")
                    case 16:
                        config.llm.bits = bits
                        print("  Bundle precision (LLM): 16-bit (plain Linear; no .scales)")
                    default:
                        throw CosyVoiceTTSError.modelLoadFailed(
                            "CosyVoice LLM bundles must be 4-bit, 8-bit quantized or 16-bit/bf16 plain Linear.")
                    }'''

CV_DIT_OLD = '''                    switch bits {
                    case 8:
                        config.flow.dit.bits = bits
                        print("  Bundle quantization (DiT): \\(config.flow.dit.bits)-bit (group_size \\(config.flow.dit.groupSize))")
                    case 16:
                        config.flow.dit.bits = bits
                        print("  Bundle precision (DiT): 16-bit (plain Linear; no .scales)")
                    default:
                        throw CosyVoiceTTSError.modelLoadFailed(
                            "CosyVoice DiT bundles must be 8-bit quantized or 16-bit/bf16 plain Linear.")
                    }'''

CV_DIT_NEW = '''                    switch bits {
                    case 4, 8:
                        config.flow.dit.bits = bits
                        print("  Bundle quantization (DiT): \\(config.flow.dit.bits)-bit (group_size \\(config.flow.dit.groupSize))")
                    case 16:
                        config.flow.dit.bits = bits
                        print("  Bundle precision (DiT): 16-bit (plain Linear; no .scales)")
                    default:
                        throw CosyVoiceTTSError.modelLoadFailed(
                            "CosyVoice DiT bundles must be 4-bit, 8-bit quantized or 16-bit/bf16 plain Linear.")
                    }'''


def find_checkouts():
    """定位 speech-swift 的 SPM checkout 目录。"""
    if len(sys.argv) > 1:
        return [sys.argv[1]]

    roots = []
    srcroot = os.environ.get("SRCROOT")
    if srcroot:
        roots.append(srcroot)
        roots += glob.glob(os.path.join(srcroot, "build-*"))
    build_dir = os.environ.get("BUILD_DIR")
    if build_dir:
        roots.append(os.path.normpath(os.path.join(build_dir, "..", "..")))
    roots += glob.glob(
        os.path.join(os.path.expanduser("~"), "Library/Developer/Xcode/DerivedData", "*"))

    found = set()
    for root in roots:
        for pattern in ("SourcePackages/checkouts/speech-swift",
                        "*/SourcePackages/checkouts/speech-swift"):
            for hit in glob.glob(os.path.join(root, pattern)):
                if os.path.isdir(hit):
                    found.add(os.path.realpath(hit))
    return sorted(found)


def patch_file(path, replacements, tail_marker=None, tail_new=None):
    """就地替换。返回 (是否改动, 说明)。"""
    with io.open(path, encoding="utf-8") as handle:
        text = handle.read()
    original = text

    if APPLIED_MARK in text:
        return False, "已打过补丁"

    # 已放行 4-bit（说明本文件也改过了）。只认锚点容易因为一处缩进
    # 差异就误判成"上游变更"，所以这里按语义特征短路。
    if all(new in text or old not in text for old, new in replacements):
        return False, "已打过补丁"

    for old, new in replacements:
        if new in text:          # 这一处已经是新的
            continue
        if text.count(old) != 1:
            return False, "锚点未唯一命中(%d) — 上游可能已变更" % text.count(old)
        text = text.replace(old, new)

    if tail_marker and tail_new:
        if tail_marker in text:
            text = text[: text.index(tail_marker)] + tail_new

    if text == original:
        return False, "无需改动"

    os.chmod(path, 0o644)        # SPM checkout 默认只读
    with io.open(path, "w", encoding="utf-8") as handle:
        handle.write(text)
    return True, "已写入"


def main():
    checkouts = find_checkouts()
    if not checkouts:
        print("patch-speech-swift: 没找到 speech-swift checkout，跳过"
              "（首次构建时属正常，解析完依赖后重跑一次即可）")
        return 0

    changed_any = False
    for root in checkouts:
        wl = os.path.join(root, "Sources", "CosyVoiceTTS", "WeightLoading.swift")
        cv = os.path.join(root, "Sources", "CosyVoiceTTS", "CosyVoiceTTS.swift")
        if not (os.path.isfile(wl) and os.path.isfile(cv)):
            print("patch-speech-swift: %s 结构不符，跳过" % root)
            continue

        wl_changed, wl_note = patch_file(
            wl,
            [(WL_LLM_OLD, WL_LLM_NEW), (WL_DIT_OLD, WL_DIT_NEW)],
            tail_marker=WL_TAIL_MARKER, tail_new=WL_TAIL_NEW)
        cv_changed, cv_note = patch_file(
            cv, [(CV_LLM_OLD, CV_LLM_NEW), (CV_DIT_OLD, CV_DIT_NEW)])

        changed_any = changed_any or wl_changed or cv_changed
        print("patch-speech-swift: %s -> WeightLoading %s; CosyVoiceTTS %s"
              % (root, wl_note, cv_note))

    print("patch-speech-swift: %s" % ("已更新" if changed_any else "无需改动"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
