#!/bin/bash
# 把 iSH「Linux 模式」的 boot 验证 harness 编成 **macOS 可执行文件**（本机直接跑，不进模拟器）。
#
# 为什么最后落在 macOS 而不是 iOS 模拟器：
#  · 本机是 Intel Mac（i5-7200U），模拟器运行时是 x86_64 —— arm64 二进制跑不了。
#  · 内核那套库（liblinux.a）必须和 app 那层同平台，否则 ld 报
#    "building for 'X', but linking in object file built for 'Y'"。
#  · 最省事的一致解：全部按 **macOS 平台** 编（内核用不带 SDKROOT 的 ninja 编出来的
#    本来就是 macOS 平台），于是产物可以直接 exec。
#
# 依赖（内核库）：
#   cd third_party/ish/build/ReleaseLinux-iphonesimulator/meson
#   env -u SDKROOT PATH=/usr/bin:/bin:$PATH ninja deps/liblinux.a libish_emu.a libfakefs.a
#   注意 link-vmlinux.sh 调的是 `libtool -static`，PATH 里必须是 **Apple 的 /usr/bin/libtool**
#   （Homebrew 的 GNU libtool 会报 "unrecognised option: '-static'"）。
#
# 产物：tests/ish_boot/ish_boot
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRCROOT="$(cd "$HERE/../.." && pwd)"
ISH="$SRCROOT/third_party/ish"
L="$ISH/build/ReleaseLinux-iphonesimulator"     # 名字里有 iphonesimulator，但产物是 macOS 平台（见上）
KOBJ="$L/meson/deps/linux"                      # 内核 objtree（generated 头在这）
KSRC="$ISH/deps/linux"                          # 内核源码树
OUT="$HERE/ish_boot"

need() {
  if [ ! -e "$1" ]; then
    echo "缺少 $1"
    echo "先按本文件顶部的命令把内核库编出来。"
    exit 1
  fi
}
need "$L/meson/deps/liblinux.a"
need "$L/meson/libish_emu.a"
need "$L/meson/libfakefs.a"

CC="$(xcrun --find clang)"
# 必须显式给 -isysroot：直接调 clang（不走 xcrun shim）时它找不到 SDK，
# 会报 'sys/types.h' file not found（本次踩过）。
MAC_SDK="$(xcrun --sdk macosx --show-sdk-path)"
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in x86_64|arm64) ;; *) HOST_ARCH=x86_64 ;; esac
echo "== 目标: $HOST_ARCH-apple-macos (直接在宿主机跑) =="

CFLAGS=(
  -target "$HOST_ARCH-apple-macos13.0"
  -isysroot "$MAC_SDK"
  -std=gnu11 -fno-common -Os -g -fblocks -fasm-blocks
  -D__KERNEL__ -U__weak
  -include linux/kconfig.h
  -include linux/compiler_types.h
  -I "$L/include"
  -I "$KSRC/arch/ish/include"
  -I "$KOBJ/arch/ish/include/generated"
  -I "$KSRC/include"
  -I "$KOBJ/include"
  -I "$KSRC/arch/ish/include/uapi"
  -I "$KOBJ/arch/ish/include/generated/uapi"
  -I "$KSRC/include/uapi"
  -I "$KOBJ/include/generated/uapi"
  -I "$ISH"
  -Wno-deprecated-declarations -Wno-unused-parameter -Wno-shorten-64-to-32
  -Wno-pointer-sign -Wno-gnu-variable-sized-type-not-at-end
)

# libarchive 没有 macOS 版就现编一个（SDK 里没有它的头，所以连头一起用仓库里的）
LA="$ISH/deps/build/Release/libarchive.a"
if [ ! -f "$LA" ]; then
  echo "== 编 libarchive (macOS) =="
  xcodebuild -project "$ISH/deps/libarchive.xcodeproj" -target libarchive -configuration Release \
    CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build > /tmp/libarchive-macos.log 2>&1 \
    || { tail -5 /tmp/libarchive-macos.log; exit 1; }
fi
need "$LA"

echo "== 编译 harness 自己的编译单元 =="
OBJS=()
# 普通 C 文件：不要带 -D__KERNEL__ / -include linux/kconfig.h（那是给内核侧用的）
compile_plain() {
  "$CC" -target "$HOST_ARCH-apple-macos13.0" -isysroot "$MAC_SDK" -std=gnu11 -fno-common -Os -g -fblocks \
    -I "$ISH" -I "$ISH/app" -I "$ISH/deps/libarchive/libarchive" \
    -Wno-deprecated-declarations -c "$1" -o "/tmp/ish_boot_$2.o"
  OBJS+=("/tmp/ish_boot_$2.o")
}
compile_kernel_side() {
  "$CC" "${CFLAGS[@]}" -I "$ISH/app" -c "$1" -o "/tmp/ish_boot_$2.o"
  OBJS+=("/tmp/ish_boot_$2.o")
}
# libiSHLinuxUser（emu_asbestos.c）在上游用的是**另一套 flag**：-DISH_LINUX=1、
# 没有 -D__KERNEL__ / -include linux/compiler_types.h（后者会把 offsetof 重定义，
# 和 emu/cpu.h 的 static_assert 打架 —— 本次踩过）。见 Xcode 的
# libiSHLinuxUser.common-args.resp。
compile_user() {
  "$CC" -target "$HOST_ARCH-apple-macos13.0" -isysroot "$MAC_SDK" \
    -std=gnu11 -fno-common -Os -g -fasm-blocks -DISH_LINUX=1 \
    -I "$L/include" \
    -I "$KSRC/arch/ish/include" -I "$KSRC/include" -I "$KOBJ/include" \
    -I "$ISH" \
    -c "$1" -o "/tmp/ish_boot_$2.o"
  OBJS+=("/tmp/ish_boot_$2.o")
}
compile_plain "$HERE/shims.c"                    shims
compile_plain "$HERE/main.c"                     main
compile_plain "$ISH/tools/fakefs.c"              import        # rootfs 导入（fakefs_import）
compile_plain "$ISH/util/fchdir.c"               fchdir
# app 层 = 上游 iSH 的 Linux 模式接口实现（libiSHLinux 的源文件）
compile_kernel_side "$ISH/app/LinuxInterop.c"          LinuxInterop
compile_kernel_side "$ISH/app/LinuxRoot.c"             LinuxRoot
compile_kernel_side "$ISH/app/LinuxTTY.c"              LinuxTTY
compile_kernel_side "$ISH/app/LinuxPTY.c"              LinuxPTY
compile_kernel_side "$ISH/app/PasteboardDeviceLinux.c" Pasteboard
# 内核侧的两个补丁（/root 目录 + percpu 页对齐）与 App **共用同一份源码**：
# 改 App 里那份就是改这里，避免"harness 能 boot、App 里那份忘了同步"这类静默分叉。
compile_kernel_side "$ISH/linux/fakefs.c"               fakefsdrv
compile_kernel_side "$SRCROOT/LumenAI/Services/Linux/lumen_kernel_addon.c" kernel_addon
compile_user "$ISH/linux/emu_asbestos.c"               emu_asbestos
# 汇编：把 __percpu_first 对齐到页边界（不这么做内核必 panic，见该文件注释）
"$CC" -target "$HOST_ARCH-apple-macos13.0" -isysroot "$MAC_SDK" \
  -c "$SRCROOT/LumenAI/Services/Linux/lumen_percpu_align.S" -o /tmp/ish_boot_percpu_align.o
OBJS+=("/tmp/ish_boot_percpu_align.o")

echo "== 链接 =="
# ⚠️ 顺序很关键：liblinux.a 必须在 app 侧对象**前面**。
# 上游 sections.S 的注释写明「section 按出现在目标文件里的顺序排列，所以这个对象
# 要第一个链进去」；initcall 也一样 —— app 侧的 device_initcall(ios_pty_init) 要挂
# devpts，而 devpts 的注册在内核侧的 module_init(init_devpts_fs)（也是 level 6）。
# app 侧排在前面就会出现 "failed to mount devpts: -ENODEV" → panic（本次实测）。
"$CC" -target "$HOST_ARCH-apple-macos13.0" -isysroot "$MAC_SDK" \
  -Wl,-force_load,"$L/meson/deps/liblinux.a" \
  "${OBJS[@]}" \
  "$L/meson/libish_emu.a" \
  "$L/meson/libfakefs.a" \
  "$LA" \
  -lsqlite3 -lz -lbz2 -liconv \
  -o "$OUT"

echo "OK $OUT"
file "$OUT"
