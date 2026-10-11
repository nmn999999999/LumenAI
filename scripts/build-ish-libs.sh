#!/bin/bash
# 构建 iSH 引擎静态库（若缺失）。产物在 third_party/ish/build/ 与 deps/build/。
# 依赖：meson + ninja（pip install meson；zig 由 patch-ish-vdso.sh 使用）。
set -euo pipefail
/bin/bash "${SRCROOT}/scripts/patch-ish-vdso.sh"
ISH="${SRCROOT}/third_party/ish"
LIB="${ISH}/build/Release-iphoneos"
if [ -f "${LIB}/libiSHApp.a" ] && [ -f "${LIB}/meson/libish.a" ] \
   && [ -f "${ISH}/deps/build/Release-iphoneos/libarchive.a" ]; then
  echo "iSH 静态库已存在，跳过"
  exit 0
fi
COMMON=(-configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="")
xcodebuild -project "${ISH}/iSH.xcodeproj"        -target libish     "${COMMON[@]}" build
xcodebuild -project "${ISH}/iSH.xcodeproj"        -target libiSHApp  "${COMMON[@]}" build
xcodebuild -project "${ISH}/deps/libarchive.xcodeproj" -target libarchive "${COMMON[@]}" build
echo "iSH 静态库构建完成"
