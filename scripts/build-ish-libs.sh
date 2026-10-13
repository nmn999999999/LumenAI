#!/bin/bash
# 构建 iSH 引擎静态库（若缺失）。产物在 third_party/ish/build/ 与 deps/build/。
# 依赖：meson + ninja（pip install meson；zig 由 patch-ish-vdso.sh 使用）。
#
# iSH 有**两套**彼此独立的引擎，默认只编第一套：
#   · NotLinux（默认，libish.a）—— iSH 自写的 Linux 系统调用模拟器。
#     LumenAI 现在链接的就是它（见 project.yml 的 OTHER_LDFLAGS）。
#   · Linux 模式（ISH_BUILD_LINUX=1，liblinux.a + libiSHLinux.a）—— 真正的 Linux 内核
#     （ish-app/linux 分支），终端会话走 linux_start_session + ObjC Terminal。
#     **默认不编**：它要先拉 359MB 的内核源码、编译十几分钟，而 LumenAI 侧还没有
#     接上 boot/rootfs/终端 UI，编出来暂时只有"可复现"的价值。
#     想编：ISH_BUILD_LINUX=1 ./scripts/build-ish-libs.sh
# ⚠️ 本机 PATH 里可能是 Homebrew 的 GNU libtool（它不认识 -static）。凡是调 libtool 的地方
#    都用绝对路径 /usr/bin/libtool，别依赖 PATH。
set -euo pipefail
# Xcode 构建阶段会注入 SRCROOT；手动跑时自解析（脚本在 <repo>/scripts/ 下）。
SRCROOT="${SRCROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export SRCROOT
/bin/bash "${SRCROOT}/scripts/patch-ish-vdso.sh"
ISH="${SRCROOT}/third_party/ish"
LIB="${ISH}/build/Release-iphoneos"
COMMON=(-configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="")

build_notlinux() {
  if [ -f "${LIB}/libiSHApp.a" ] && [ -f "${LIB}/meson/libish.a" ] \
     && [ -f "${ISH}/deps/build/Release-iphoneos/libarchive.a" ]; then
    echo "iSH 静态库已存在，跳过"
    return 0
  fi
  xcodebuild -project "${ISH}/iSH.xcodeproj"        -target libish     "${COMMON[@]}" build
  xcodebuild -project "${ISH}/iSH.xcodeproj"        -target libiSHApp  "${COMMON[@]}" build
  echo "iSH 静态库构建完成"
}

# libarchive 是**两种模式都要**的（解 rootfs tarball / fakefs），所以单独一步，
# 别绑在 NotLinux 那条路径上（跳过 NotLinux 时它会被漏掉）。
build_libarchive() {
  if [ -f "${ISH}/deps/build/Release-iphoneos/libarchive.a" ]; then
    echo "libarchive 已存在，跳过"
    return 0
  fi
  xcodebuild -project "${ISH}/deps/libarchive.xcodeproj" -target libarchive "${COMMON[@]}" build
}

# Linux 模式：内核源码是 update=none 的子模块（不会被 clone），缺失时按官方脚本拉取。
build_linux_mode() {
  L="${ISH}/build/ReleaseLinux-iphoneos"
  if [ ! -f "${L}/liblinux.a" ] || [ ! -f "${L}/libiSHLinux.a" ]; then
    build_linux_engines
  fi
  build_linux_app_package
}

build_linux_engines() {
  if [ ! -f "${ISH}/deps/linux/arch/ish/x86/Makefile" ]; then
    echo "拉取 Linux 模式内核源码（ish-app/linux，sparse+depth1）…"
    # clone-linux.sh 里全是**相对路径**（deps/linux、deps/linux-sparse.txt），必须在 iSH
    # 仓库根目录下跑。从 LumenAI 根直接调会先报 "pathspec 'deps/linux' did not match"，
    # 再拿空 URL 去 clone —— 于是整个构建挂掉（CI run 38410175462 即如此，本机因为
    # deps/linux 目录早就位、从没走到这条分支，所以一直没暴露）。
    (cd "${ISH}" && /bin/sh deps/clone-linux.sh)
    /bin/bash "${SRCROOT}/scripts/patch-ish-vdso.sh"   # 内核 vdso 的链接补丁在 clone 之后才生效
  fi
  LCOMMON=(-configuration ReleaseLinux -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="")
  xcodebuild -project "${ISH}/iSH.xcodeproj" -target liblinux    "${LCOMMON[@]}" build
  xcodebuild -project "${ISH}/iSH.xcodeproj" -target libiSHLinux "${LCOMMON[@]}" build
  # libiSHLinuxUser 是**独立 target**，不是上面两个的依赖 —— 不单独编就没有
  # libiSHLinuxUser.a，合成 liblumen-linux.a 时 /usr/bin/libtool 会直接
  # "can't open file" 挂掉（CI run 38411310394）。本机那份是手动编出来的，所以一直没暴露。
  xcodebuild -project "${ISH}/iSH.xcodeproj" -target libiSHLinuxUser "${LCOMMON[@]}" build
  echo "iSH Linux 模式库构建完成"
}

# ── App 侧的链接包：合成 liblumen-linux.a ────────────────────────────────────
# 为什么要自己合成一个库，而不是让 Xcode 分别链那几个 .a：
#
#   initcall 的**执行顺序 = 目标文件在链接命令行上的先后**。内核侧的
#   init_devpts_fs（level 6，liblinux.a）必须在 app 侧的 ios_pty_init（同样 level 6，
#   libiSHLinux.a）之前跑完 —— 否则 do_mount("devpts") 返回 -ENODEV，而
#   app/LinuxPTY.c 里那一行是 `panic(...)`，不是 warning（实测：harness 里 app 对象
#   排在 liblinux 前面时就是这么 panic 的）。
#
#   Xcode 的链接行形如 `<app 的所有 .o> … <OTHER_LDFLAGS>`，-force_load 只会落在 app
#   对象**之后** —— 于是内核成员必然排在 app 层之后，顺序是反的。
#
#   所以：在这里把成员顺序固定成「内核 → app 层 → 我们的内核补丁 → rootfs 导入器」，
#   Xcode 那边只 -force_load 这一个库。这个顺序与 harness 实测能 boot 的那条一致。
build_linux_app_package() {
  L="${ISH}/build/ReleaseLinux-iphoneos"
  KOBJ="${L}/meson/deps/linux"
  KSRC="${ISH}/deps/linux"
  OUT="${L}/liblumen-linux.a"
  WORK="${L}/lumen-addons"
  IOS_MIN="${IPHONEOS_DEPLOYMENT_TARGET:-26.0}"
  IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
  CC="$(xcrun --find clang)"
  TRIPLE="arm64-apple-ios${IOS_MIN}"

  mkdir -p "${WORK}"

  # ① 我们的内核侧补丁（要带 __KERNEL__ / kconfig.h，和内核自己的编译单元同款 flag）
  "${CC}" -target "${TRIPLE}" -isysroot "${IOS_SDK}" -std=gnu11 -fno-common -Os -g \
    -fblocks -fasm-blocks -D__KERNEL__ -U__weak \
    -include linux/kconfig.h -include linux/compiler_types.h \
    -I "${L}/include" \
    -I "${KSRC}/arch/ish/include" -I "${KOBJ}/arch/ish/include/generated" \
    -I "${KSRC}/include" -I "${KOBJ}/include" \
    -I "${KSRC}/arch/ish/include/uapi" -I "${KOBJ}/arch/ish/include/generated/uapi" \
    -I "${KSRC}/include/uapi" -I "${KOBJ}/include/generated/uapi" \
    -I "${ISH}" \
    -Wno-deprecated-declarations -Wno-unused-parameter -Wno-shorten-64-to-32 \
    -Wno-pointer-sign -Wno-gnu-variable-sized-type-not-at-end \
    -c "${SRCROOT}/LumenAI/Services/Linux/lumen_kernel_addon.c" -o "${WORK}/lumen_kernel_addon.o"

  # ② __percpu_first 的页对齐（纯汇编，不需要内核头）
  "${CC}" -target "${TRIPLE}" -isysroot "${IOS_SDK}" \
    -c "${SRCROOT}/LumenAI/Services/Linux/lumen_percpu_align.S" -o "${WORK}/lumen_percpu_align.o"

  # ③ rootfs 导入器（tools/fakefs.c）+ 它需要的 fchdir：普通的用户态 C，不带内核 flag
  "${CC}" -target "${TRIPLE}" -isysroot "${IOS_SDK}" -std=gnu11 -fno-common -Os -g \
    -I "${ISH}" -I "${ISH}/app" -I "${ISH}/deps/libarchive/libarchive" \
    -Wno-deprecated-declarations \
    -c "${ISH}/tools/fakefs.c"  -o "${WORK}/fakefs_import.o"
  "${CC}" -target "${TRIPLE}" -isysroot "${IOS_SDK}" -std=gnu11 -fno-common -Os -g \
    -I "${ISH}" -c "${ISH}/util/fchdir.c" -o "${WORK}/fchdir.o"

  # ④ 合成：成员顺序就是 initcall 顺序（内核在前）
  rm -f "${OUT}"
  /usr/bin/libtool -static -o "${OUT}" \
    "${L}/meson/deps/liblinux.a" \
    "${L}/libiSHLinux.a" \
    "${L}/libiSHLinuxUser.a" \
    "${WORK}/lumen_kernel_addon.o" \
    "${WORK}/lumen_percpu_align.o" \
    "${WORK}/fakefs_import.o" \
    "${WORK}/fchdir.o"

  echo "== 合成 ${OUT} =="
  lipo -info "${OUT}"
  echo "   成员数 $(ar t "${OUT}" | grep -vc SYMDEF)"
  for sym in _run_kernel _actuate_kernel _linux_start_session _init_devpts_fs _fakefs_import; do
    printf "   %-22s %s\n" "${sym}" "$(nm -j "${OUT}" 2>/dev/null | grep -cx "${sym}")"
  done
}

# NotLinux 那套（libish.a / libiSHApp.a）**App 已经不用了**：LumenAI 现在链的是 Linux 模式
# （真内核）。CI 里用 ISH_SKIP_NOTLINUX=1 跳过它，省掉一次没意义的编译；本地想编仍可编。
if [ "${ISH_SKIP_NOTLINUX:-0}" != "1" ]; then build_notlinux; fi
build_libarchive
if [ "${ISH_BUILD_LINUX:-0}" = "1" ]; then build_linux_mode; fi
