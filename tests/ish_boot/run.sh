#!/bin/bash
# 在本机把 iSH 的 Linux 内核真拉起来（不碰 LumenAI 的 App 包）。
#
#   ./tests/ish_boot/run.sh [rootfs.tar.gz] [root目录] [等待秒数]
#
# 本机是 Intel Mac：iOS 模拟器运行时是 x86_64，所以所有库和 harness 都按
# x86_64-apple-ios15.0-simulator 编（见 build.sh）。模拟器平台的二进制本来就是
# macOS 进程，能直接在宿主机 exec，所以优先直接跑；跑不起来再退回 simctl spawn。
#
# 默认 rootfs：iSH 官方 appstore-apk rootfs（app/iSH.xcconfig 的 ROOTFS_URL），
# 比自己拼 Alpine minirootfs 更接近上游真实形态。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARBALL="${1:-/tmp/ish-rootfs/iSH-root.tar.gz}"
ROOT="${2:-/tmp/ish-rootfs/root}"
WAIT="${3:-30}"
if [ -n "${LUMEN_NET_PROBE:-}" ] && [ "$WAIT" = "30" ]; then WAIT=180; fi
BIN="$HERE/ish_boot"

[ -x "$BIN" ] || { echo "先跑 $HERE/build.sh"; exit 1; }
[ -f "$TARBALL" ] || { echo "没有 rootfs: $TARBALL"; exit 1; }

run_direct() {
  echo "== 直接在宿主机跑（模拟器平台二进制 == macOS 进程）=="
  "$BIN" "$TARBALL" "$ROOT" "$WAIT"
}

run_in_sim() {
  echo "== 退回 simctl spawn =="
  if ! xcrun simctl list devices booted | grep -q "(Booted)"; then
    UDID="$(xcrun simctl list devices available | grep -m1 "iPhone" | grep -oE '[0-9A-F-]{36}' || true)"
    [ -n "$UDID" ] || { echo "没有可用的模拟器设备"; return 1; }
    echo "== 启动模拟器 $UDID =="
    xcrun simctl boot "$UDID" 2>/dev/null || true
    for _ in $(seq 1 60); do
      xcrun simctl list devices booted | grep -q "(Booted)" && break
      sleep 1
    done
  fi
  xcrun simctl spawn booted "$BIN" "$TARBALL" "$ROOT" "$WAIT"
}

echo "== ish_boot $TARBALL -> $ROOT (wait ${WAIT}s) =="
set +e
run_direct
CODE=$?
set -e

if [ "$CODE" -eq 126 ] || [ "$CODE" -eq 127 ]; then
  set +e
  run_in_sim
  CODE=$?
  set -e
fi

echo "== 退出码 $CODE =="
case "$CODE" in
  0) echo "PASS 内核起来了" ;;
  4) echo "FAIL 内核 panic" ;;
  5) echo "WARN 没有 console 输出（不确定），看上面日志" ;;
  6) echo "FAIL 卡在早期启动" ;;
  *) echo "FAIL 失败 (code=$CODE)" ;;
esac
exit "$CODE"
