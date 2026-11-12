#!/usr/bin/env bash
# ============================================================
#  直接编译 dylib（不依赖 substrate、不生成 deb）
#  产物：build/YuanbaoCheckin.dylib  -> 用 TrollFools 注入元宝
#
#  只需要：clang + 一份 iOS SDK
#  找 SDK 的顺序：
#     1) 环境变量 SDK=/path/to/iPhoneOSxx.sdk
#     2) $THEOS/sdks/iPhoneOS*.sdk
#     3) ./sdk/iPhoneOS*.sdk
#  其它环境变量：
#     MIN_IOS   最低系统版本（默认 14.0）
#     ARCHS     架构（默认 "arm64"；需要时设 ARCHS="arm64 arm64e"）
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

MIN_IOS="${MIN_IOS:-14.0}"
ARCHS="${ARCHS:-arm64}"
THEOS="${THEOS:-$HOME/theos}"

# ---------- 找 SDK ----------
find_sdk() {
  if [ -n "${SDK:-}" ] && [ -d "${SDK}" ]; then echo "$SDK"; return; fi
  local d
  for d in "$THEOS"/sdks/iPhoneOS*.sdk ./sdk/iPhoneOS*.sdk; do
    [ -d "$d" ] && { echo "$d"; return; }
  done
}
SDK="$(find_sdk || true)"
if [ -z "${SDK:-}" ] || [ ! -d "$SDK" ]; then
  echo "找不到 iOS SDK。设置 SDK=/path/to/iPhoneOSxx.sdk，或放到 $THEOS/sdks/ 或 ./sdk/" >&2
  exit 1
fi
echo "[build] SDK   = $SDK"
echo "[build] MIN   = iOS $MIN_IOS"
echo "[build] ARCHS = $ARCHS"

# ---------- 找 clang ----------
CLANG="${CLANG:-}"
if [ -z "$CLANG" ]; then
  for c in "$THEOS"/toolchain/*/bin/clang "$THEOS"/toolchain/*/*/bin/clang; do
    [ -x "$c" ] && CLANG="$c" && break
  done
fi
[ -z "$CLANG" ] && CLANG="$(command -v clang || true)"
[ -z "$CLANG" ] && { echo "找不到 clang" >&2; exit 1; }
echo "[build] clang = $CLANG ($("$CLANG" --version 2>/dev/null | head -1))"

# ---------- 源文件 ----------
SRC=(Tweak.m YBEngine.m YBTouch.m YBScreen.m YBConfig.m YBStep.m YBLog.m YBUI.m)
for f in "${SRC[@]}"; do
  [ -f "$f" ] || { echo "缺少源文件: $f" >&2; exit 1; }
done

ARCH_FLAGS=(); for a in $ARCHS; do ARCH_FLAGS+=(-arch "$a"); done

mkdir -p build
set -x
"$CLANG" -dynamiclib \
  "${ARCH_FLAGS[@]}" \
  -isysroot "$SDK" \
  -miphoneos-version-min="$MIN_IOS" \
  -fobjc-arc -O2 \
  -Wno-deprecated-declarations \
  -I. \
  -framework Foundation -framework UIKit -framework Vision \
  -framework CoreGraphics -framework CoreImage -framework QuartzCore \
  "${SRC[@]}" \
  -install_name @executable_path/Frameworks/YuanbaoCheckin.dylib \
  -o build/YuanbaoCheckin.dylib
set +x

# ---------- 可选伪签名（TrollFools 注入时会重签，通常不需要） ----------
if [ "${SIGN:-0}" = "1" ]; then
  if command -v ldid >/dev/null 2>&1; then
    ldid -S build/YuanbaoCheckin.dylib && echo "[build] 已 ldid 伪签名"
  elif command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - build/YuanbaoCheckin.dylib && echo "[build] 已 codesign 临时签名"
  else
    echo "[build] 没找到 ldid/codesign，跳过签名（一般不影响 TrollFools）"
  fi
fi

echo "[build] 架构检查："
( command -v lipo >/dev/null 2>&1 && lipo -info build/YuanbaoCheckin.dylib ) || file build/YuanbaoCheckin.dylib || true
ls -lh build/YuanbaoCheckin.dylib
echo "[build] 完成 -> build/YuanbaoCheckin.dylib"