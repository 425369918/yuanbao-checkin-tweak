#!/usr/bin/env bash
# ============================================================
#  直接编译 dylib（不依赖 substrate、不生成 deb）
#  产物：build/YuanbaoCheckin.dylib  -> 用 TrollFools 注入元宝
#
#  可用环境变量：
#     SDK        指定 iPhoneOSxx.sdk（默认自动查找 / 自动下载）
#     CLANG      指定 clang（默认优先用 theos 工具链里的）
#     THEOS      theos 根目录（默认 $HOME/theos）
#     MIN_IOS    最低系统版本（默认 14.0）
#     ARCHS      架构（默认 "arm64"）
#     FUSE_LD    链接器（Linux 交叉编译时用 lld，默认自动）
#     SIGN       1 = 编译完顺手伪签名（默认关，TrollFools 注入时会重签）
#     OUT        产物路径（默认 build/YuanbaoCheckin.dylib）
#     EXTRA_CFLAGS 追加编译参数，例："-DYB_SAFE=1" 编安全版
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

MIN_IOS="${MIN_IOS:-14.0}"
ARCHS="${ARCHS:-arm64}"
SDK_VER="${SDK_VER:-16.5}"
THEOS="${THEOS:-$HOME/theos}"
OUT="${OUT:-build/YuanbaoCheckin.dylib}"
EXTRA_CFLAGS="${EXTRA_CFLAGS:-}"

log() { echo "[build] $*"; }
die() { echo "[build][ERROR] $*" >&2; exit 1; }

# ---------- 找 SDK ----------
find_sdk() {
  if [ -n "${SDK:-}" ] && [ -d "${SDK}/usr/include" ]; then echo "$SDK"; return 0; fi
  local d
  for d in "$THEOS"/sdks/iPhoneOS*.sdk ./sdk/iPhoneOS*.sdk /opt/theos/sdks/iPhoneOS*.sdk; do
    [ -d "$d/usr/include" ] && { echo "$d"; return 0; }
  done
  return 1
}

fetch_sdk() {
  log "未找到可用 SDK，尝试下载 iPhoneOS${SDK_VER}.sdk ..."
  mkdir -p ./sdk
  local url="https://github.com/theos/sdks/releases/latest/download/iPhoneOS${SDK_VER}.sdk.tar.xz"
  if curl -fL --retry 3 --connect-timeout 30 -o /tmp/sdk.tar.xz "$url"; then
    tar -xf /tmp/sdk.tar.xz -C ./sdk || die "SDK 解压失败"
    log "SDK 已解压到 ./sdk"
  else
    log "下载 SDK 失败：$url"
  fi
}

SDK_PATH="$(find_sdk || true)"
if [ -z "${SDK_PATH:-}" ]; then
  fetch_sdk
  SDK_PATH="$(find_sdk || true)"
fi
[ -n "${SDK_PATH:-}" ] || die "找不到 iOS SDK；可设置 SDK=/path/to/iPhoneOSxx.sdk，或放到 \$THEOS/sdks/ 或 ./sdk/"
export SDK="$SDK_PATH"

# ---------- 找 clang ----------
CLANG="${CLANG:-}"
if [ -z "$CLANG" ]; then
  for c in "$THEOS"/toolchain/*/*/bin/clang "$THEOS"/toolchain/*/bin/clang /opt/theos/toolchain/*/*/bin/clang; do
    [ -x "$c" ] && CLANG="$c" && break
  done
fi
[ -z "$CLANG" ] && CLANG="$(command -v clang || true)"
[ -n "$CLANG" ] || die "找不到 clang"

# 让 clang 能找到同目录下的 ld64.lld（Linux 交叉编译必须）
CLANG_DIR="$(dirname "$CLANG")"
case ":$PATH:" in *":$CLANG_DIR:"*) ;; *) export PATH="$CLANG_DIR:$PATH" ;; esac

log "==================== 环境 ===================="
log "host  = $(uname -s) $(uname -m)"
log "clang = $CLANG"
"$CLANG" --version 2>/dev/null | head -2 || true
log "ld64  = $(command -v ld64.lld || echo '未在 PATH 中找到 ld64.lld')"
log "tools = $(ls "$CLANG_DIR" 2>/dev/null | grep -Ei '^(clang|ld|ld64|lld|ar|strip)' | tr '\n' ' ')"
log "SDK   = $SDK"
log "MIN   = iOS $MIN_IOS"
log "ARCHS = $ARCHS"
log "OUT   = $OUT"
[ -n "$EXTRA_CFLAGS" ] && log "EXTRA = $EXTRA_CFLAGS"
log "============================================="

[ -d "$SDK/usr/include" ] || die "SDK 不完整：$SDK（缺少 usr/include）"

# ---------- 源文件 ----------
SRC=(Tweak.m YBEngine.m YBTouch.m YBScreen.m YBConfig.m YBStep.m YBLog.m YBUI.m)
for f in "${SRC[@]}"; do
  [ -f "$f" ] || die "缺少源文件: $f"
done

ARCH_FLAGS=(); for a in $ARCHS; do ARCH_FLAGS+=(-arch "$a"); done

# 非 Darwin 主机（Linux CI）上交叉编译 Mach-O：显式给 target
# 链接器默认交给工具链自己决定（clang 11 的工具链不认 -fuse-ld=lld，只有显式指定时才加）
HOST_OS="$(uname -s)"
TARGET_FLAGS=(); LINK_FLAGS=()
if [ "$HOST_OS" != "Darwin" ]; then
  TARGET_FLAGS+=(-target "arm64-apple-ios${MIN_IOS}")
  [ -n "${FUSE_LD:-}" ] && LINK_FLAGS+=(-fuse-ld="${FUSE_LD}")
fi
# 注入到 App 的 dylib：系统/ObjC 运行时符号留到加载时解析
LINK_FLAGS+=(-Wl,-undefined,dynamic_lookup)
LINK_FLAGS+=(-Wl,-install_name,@executable_path/Frameworks/"$(basename "$OUT")")

mkdir -p "$(dirname "$OUT")"
set -x
"$CLANG" -dynamiclib \
  "${ARCH_FLAGS[@]}" \
  "${TARGET_FLAGS[@]}" \
  -isysroot "$SDK" \
  -miphoneos-version-min="$MIN_IOS" \
  -fobjc-arc -O2 \
  -Wno-deprecated-declarations -Wno-unused-variable \
  -I. \
  ${EXTRA_CFLAGS} \
  -framework Foundation -framework UIKit -framework Vision \
  -framework CoreGraphics -framework CoreImage -framework QuartzCore \
  "${SRC[@]}" \
  "${LINK_FLAGS[@]}" \
  -o "$OUT"
set +x

[ -f "$OUT" ] || die "没有生成 $OUT"

# ---------- 可选伪签名（TrollFools 注入时会重签，通常不需要） ----------
if [ "${SIGN:-0}" = "1" ]; then
  if command -v ldid >/dev/null 2>&1; then
    ldid -S "$OUT" && log "已 ldid 伪签名"
  else
    log "没找到 ldid，跳过签名（不影响 TrollFools 注入）"
  fi
fi

log "架构检查："
( command -v lipo >/dev/null 2>&1 && lipo -info "$OUT" ) || file "$OUT" || true
ls -lh "$OUT"
log "完成 -> $OUT"
