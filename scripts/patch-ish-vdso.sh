#!/bin/bash
# 给 iSH 的 vdso 打补丁：用 zig（内置 clang+lld）代替 Homebrew LLVM，
# 避免依赖 ld.lld（本机 Homebrew 是 Tier3，装不了 llvm；CI runner 同理）。幂等。
#
# iSH 里有**两套** vdso，都要过一遍：
#   1. third_party/ish/vdso/meson.build —— NotLinux（原本的 iSH 内核）用；
#   2. deps/linux/arch/ish/x86/Makefile —— Linux 模式那套真内核（liblinux）用，
#      它的链接命令写死 `-fuse-ld=lld`，而 Xcode 只带 ld/ld-classic，没有 ld.lld，
#      clang 会直接报 `invalid linker name in argument '-fuse-ld=lld'`。
#      那里**只换链接**（编译仍用 clang，它本来就能产出 i386 ELF 目标文件）。
# deps/linux 是 update=none 的子模块（默认不拉），缺失时第 2 步自动跳过。
#
# zig 的解析顺序（三选一，谁先找到用谁）：
#   1. 环境变量 ISH_ZIG（显式指定，构建脚本/CI 用）
#   2. PATH 里的 zig
#   3. pip 装的 ziglang 包内的 zig 二进制（`pip install ziglang` —— CI 走这条）
# 为什么不在脚本里写死绝对路径：Python 版本一变路径就失效，而失败现象是
# "vdso 编译不过"，看起来像 iSH 源码的问题 —— 最难查的那类。
set -euo pipefail
# Xcode 构建阶段会注入 SRCROOT；手动跑时自解析（脚本在 <repo>/scripts/ 下）。
SRCROOT="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
M="${SRCROOT}/third_party/ish/vdso/meson.build"
C="${SRCROOT}/third_party/ish/vdso/check-cc.sh"
[ -f "$M" ] || { echo "iSH 子模块缺失，跳过"; exit 0; }
ZIG="${ISH_ZIG:-}"
if [ -z "$ZIG" ] && command -v zig >/dev/null 2>&1; then ZIG="$(command -v zig)"; fi
if [ -z "$ZIG" ]; then
  ZIG="$(python3 - <<'PY' 2>/dev/null || true
import os
try:
    import ziglang
except Exception:
    raise SystemExit(0)
p = os.path.join(os.path.dirname(ziglang.__file__), "zig")
print(p if os.path.exists(p) else "")
PY
)"
fi
if [ -z "$ZIG" ]; then
  ZIG="$(ls -1 /usr/local/lib/python3*/site-packages/ziglang/zig 2>/dev/null | head -1)"
fi
if [ -z "$ZIG" ]; then
  echo "找不到 zig：设置 ISH_ZIG=<zig 路径>，或 pip install ziglang" >&2
  exit 1
fi

echo "iSH vdso 编译器：$ZIG"

# ── 1) NotLinux 侧的 vdso（meson）──────────────────────────────
# 幂等：已打过就只把记录下来的 zig 路径刷成最新（换 Python 版本后路径会失效）。
python3 - "$M" "$C" "$ZIG" <<'PY'
import re, sys
m, c, zig = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(m).read()
if "clang = find_program" in s:
    s = s.replace(
      "clang = find_program('/usr/local/opt/llvm/bin/clang', '/opt/homebrew/opt/llvm/bin/clang', '/opt/local/bin/clang', 'clang')",
      "zig = find_program('%s', 'zig')" % zig)
    s = s.replace("run_command(check_cc, clang,", "run_command(check_cc, zig,")
    s = s.replace("vdso_compiler = [clang, '-target', 'i386-linux', '-fuse-ld=lld']",
                  "vdso_compiler = [zig, 'cc', '-target', 'x86-linux-gnu']")
    print("patched iSH vdso(meson) -> zig")
else:
    s2 = re.sub(r"zig = find_program\('[^']*'", "zig = find_program('%s'" % zig, s, count=1)
    if s2 != s:
        s = s2
        print("iSH vdso(meson) zig 路径已更新 -> %s" % zig)
    else:
        print("iSH vdso(meson) 已是 zig，无需改动")
open(m, "w").write(s)

t = open(c).read()
t2 = t.replace("$cc -target i386-linux -fuse-ld=lld", "$cc cc -target x86-linux-gnu")
if t2 != t:
    open(c, "w").write(t2)
    print("patched check-cc.sh -> zig")
PY

# ── 2) Linux 模式内核自带的 vdso（deps/linux）───────────────────
K="${SRCROOT}/third_party/ish/deps/linux/arch/ish/x86/Makefile"
if [ -f "$K" ]; then
  python3 - "$K" "$ZIG" <<'PY'
import re, sys
k, zig = sys.argv[1], sys.argv[2]
s = open(k).read()
old_link = "cmd_vdsold = $(VDSOCC) $(VDSO_CFLAGS) -fuse-ld=lld -nostdlib \\"
new_link = "cmd_vdsold = $(VDSO_LD) -target x86-linux-gnu -nostdlib \\"
if old_link in s:
    s = s.replace(old_link, new_link)
    s = s.replace("quiet_cmd_vdsold = VDSOLD  $@",
                  "quiet_cmd_vdsold = VDSOLD  $@\n"
                  "# Patched for LumenAI: 系统没有 ld.lld（Xcode 只带 ld/ld-classic），\n"
                  "# vdso 的**链接**改用 zig 自带的 lld；编译仍走上面的 VDSOCC(clang)。\n"
                  "VDSO_LD = %s cc" % zig)
    print("patched kernel vdso(arch/ish/x86) -> zig ld")
else:
    s2 = re.sub(r"VDSO_LD = \S+ cc", "VDSO_LD = %s cc" % zig, s, count=1)
    if s2 != s:
        s = s2
        print("kernel vdso zig 路径已更新 -> %s" % zig)
    else:
        print("kernel vdso(arch/ish/x86) 已是 zig，无需改动")
open(k, "w").write(s)
PY
else
  echo "Linux 模式内核未拉取（deps/linux 为空），跳过内核 vdso 补丁"
fi
