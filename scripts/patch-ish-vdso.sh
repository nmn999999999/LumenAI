#!/bin/bash
# 给 iSH 的 vdso 打补丁：用 zig（内置 clang+lld）代替 Homebrew LLVM，
# 避免依赖 ld.lld（本机 Homebrew 是 Tier3，装不了 llvm）。幂等。
set -euo pipefail
M="${SRCROOT}/third_party/ish/vdso/meson.build"
C="${SRCROOT}/third_party/ish/vdso/check-cc.sh"
[ -f "$M" ] || { echo "iSH 子模块缺失，跳过"; exit 0; }
if grep -q "ziglang/zig" "$M"; then echo "iSH vdso 已打过补丁"; exit 0; fi
python3 - "$M" "$C" <<'PY'
import sys
m, c = sys.argv[1], sys.argv[2]
s = open(m).read()
s = s.replace(
  "clang = find_program('/usr/local/opt/llvm/bin/clang', '/opt/homebrew/opt/llvm/bin/clang', '/opt/local/bin/clang', 'clang')",
  "zig = find_program('/usr/local/lib/python3.14/site-packages/ziglang/zig', 'zig')")
s = s.replace("run_command(check_cc, clang,", "run_command(check_cc, zig,")
s = s.replace("vdso_compiler = [clang, '-target', 'i386-linux', '-fuse-ld=lld']",
              "vdso_compiler = [zig, 'cc', '-target', 'x86-linux-gnu']")
open(m, "w").write(s)
t = open(c).read().replace("$cc -target i386-linux -fuse-ld=lld", "$cc cc -target x86-linux-gnu")
open(c, "w").write(t)
print("patched iSH vdso -> zig")
PY
