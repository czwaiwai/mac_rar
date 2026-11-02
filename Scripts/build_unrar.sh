#!/usr/bin/env bash
# =============================================================================
# build_unrar.sh — 自建 RARLAB UnRAR 官方源码 XCFramework（arm64）
# =============================================================================
#
# 背景:
#   libarchive 的 RAR reader 硬编码不支持加密数据（与 OpenSSL 无关），故迁移到
#   RARLAB UnRAR 官方源码（C++），以完整支持 RAR4/RAR5 加密解压（含 -hp 头部加密）。
#   本脚本锁定源码版本 unrarsrc-7.1.6，记录 SHA256 做可复现校验，编译 arm64
#   libunrar.a，编译 C shim（Sources/CUnRAR/unrar_shim.cpp），静态合并后产出
#   Vendor/unrar.xcframework（framework 形态，含 Headers + Modules/module.modulemap），
#   并把 license.txt 复制到 Vendor/unrar-src/LICENSE（许可合规）。
#
# 用法:
#   Scripts/build_unrar.sh [选项]
#
# 选项:
#   --version <ver>   UnRAR 源码版本。默认 7.1.6
#   --output <path>   XCFramework 输出路径。默认 Vendor/unrar.xcframework
#   --workdir <path>  中间产物目录。默认 .build/unrar-build
#   --keep-work       保留中间产物（默认保留源码目录与 tarball，仅清理临时 obj）
#   -h, --help        显示本帮助
#
# 依赖:
#   curl / tar / make / clang++ / xcrun(libtool, xcodebuild) / shasum
#
# 许可（UnRAR license.txt 第 2 条原文，纯解压用途合规）：
#   UnRAR source code may be used in any software to handle
#   RAR archives without limitations free of charge, but cannot be
#   used to develop RAR (WinRAR) compatible archiver and to
#   re-create RAR compression algorithm, which is proprietary.
#   Distribution of modified UnRAR source code in separate form
#   or as a part of other software is permitted, provided that
#   full text of this paragraph, starting from "UnRAR source code"
#   words, is included in license, or in documentation if license
#   is not available, and in source code comments of resulting package.
# =============================================================================

set -euo pipefail

# --- 常量 ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHIM_DIR="${PROJECT_DIR}/Sources/CUnRAR"

# --- 变量 ---------------------------------------------------------------
UNRAR_VERSION="7.3.2"
# 锁定版本的可复现校验和（SHA256，用于防篡改 / 离线缓存校验）。
# 注：7.1.6 在「回调 + 分卷」场景下首卷跨卷文件会误报 ERAR_BAD_DATA（DLL 模式缺陷），
#     7.3.2 已修复，故锁定 7.3.2（RAR_DLL_VERSION 11）。
UNRAR_SHA256="f61a1160d6e2ebbda2ad353c8e82f62ab4312f97fde23c6c2c982d25e0014f99"
OUTPUT_PATH="${PROJECT_DIR}/Vendor/unrar.xcframework"
WORKDIR="${PROJECT_DIR}/.build/unrar-build"
KEEP_WORK=0
ARCH="arm64"
MACOSX_DEPLOYMENT_TARGET="12.0"

# --- 工具函数 -----------------------------------------------------------
usage() {
    sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[build_unrar] %s\n' "$*"
}

# --- 参数解析 -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            UNRAR_VERSION="$2"; shift 2 ;;
        --version=*)
            UNRAR_VERSION="${1#*=}"; shift ;;
        --output)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            OUTPUT_PATH="$2"; shift 2 ;;
        --output=*)
            OUTPUT_PATH="${1#*=}"; shift ;;
        --workdir)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            WORKDIR="$2"; shift 2 ;;
        --workdir=*)
            WORKDIR="${1#*=}"; shift ;;
        --keep-work)
            KEEP_WORK=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "未知选项: $1（-h/--help 查看帮助）" ;;
    esac
done

# --- 前置检查 -----------------------------------------------------------
command -v curl >/dev/null 2>&1 || die "缺少 curl"
command -v make >/dev/null 2>&1 || die "缺少 make"
command -v shasum >/dev/null 2>&1 || die "缺少 shasum"
command -v xcrun >/dev/null 2>&1 || die "缺少 xcrun"
command -v xcodebuild >/dev/null 2>&1 || die "缺少 xcodebuild"
command -v clang++ >/dev/null 2>&1 || die "缺少 clang++"

[[ -f "${SHIM_DIR}/unrar_shim.h" ]] || die "找不到 shim 头: ${SHIM_DIR}/unrar_shim.h"
[[ -f "${SHIM_DIR}/unrar_shim.cpp" ]] || die "找不到 shim 实现: ${SHIM_DIR}/unrar_shim.cpp"

log "UnRAR:    v${UNRAR_VERSION}"
log "输出:      $OUTPUT_PATH"
log "中间目录:  $WORKDIR"

# --- 下载 / 校验 / 解压源码 -------------------------------------------
TARBALL="${WORKDIR}/unrarsrc-${UNRAR_VERSION}.tar.gz"
SRC_DIR="${WORKDIR}/unrar"

mkdir -p "$WORKDIR"

if [[ ! -f "$TARBALL" ]]; then
    URL="https://www.rarlab.com/rar/unrarsrc-${UNRAR_VERSION}.tar.gz"
    log "下载源码: $URL"
    curl -sL --retry 5 --retry-delay 2 -o "$TARBALL" "$URL" || die "下载失败"
fi
[[ -s "$TARBALL" ]] || die "tarball 为空: $TARBALL"

log "校验 SHA256..."
ACTUAL_SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
if [[ "$ACTUAL_SHA" != "$UNRAR_SHA256" ]]; then
    die "SHA256 校验失败: 期望 $UNRAR_SHA256，实际 $ACTUAL_SHA"
fi
log "SHA256 校验通过"

if [[ ! -d "$SRC_DIR" ]]; then
    log "解压源码..."
    # 官方 tarball 顶层目录固定为 unrar/
    tar xzf "$TARBALL" -C "$WORKDIR" || die "解压失败"
fi
[[ -f "$SRC_DIR/dll.hpp" ]] || die "未找到 dll.hpp: $SRC_DIR/dll.hpp"
[[ -f "$SRC_DIR/license.txt" ]] || die "未找到 license.txt: $SRC_DIR/license.txt"

# --- 编译 libunrar.a（arm64 静态库） -----------------------------------
log "make lib（${ARCH}）..."
CXXFLAGS_COMMON="-O2 -std=c++11 -arch ${ARCH} -mmacosx-version-min=${MACOSX_DEPLOYMENT_TARGET} -fPIC -Wno-logical-op-parentheses -Wno-switch -Wno-dangling-else"
(
    cd "$SRC_DIR"
    make -f makefile lib \
        CXX="clang++" \
        CXXFLAGS="$CXXFLAGS_COMMON" \
        LDFLAGS="-pthread" \
        > "${WORKDIR}/make.log" 2>&1 \
        || { tail -40 "${WORKDIR}/make.log"; die "make lib 失败"; }
)
LIBUNRAR_A="${SRC_DIR}/libunrar.a"
[[ -f "$LIBUNRAR_A" ]] || die "未找到静态库: $LIBUNRAR_A"

# --- 编译 C shim -------------------------------------------------------
log "编译 shim..."
SHIM_OBJ="${WORKDIR}/unrar_shim.o"
clang++ -arch "${ARCH}" -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET}" \
    -std=c++11 -O2 \
    -I"${SRC_DIR}" -I"${SHIM_DIR}" \
    -c "${SHIM_DIR}/unrar_shim.cpp" -o "$SHIM_OBJ" \
    || die "编译 shim 失败"

# --- 静态合并 shim + libunrar.a ---------------------------------------
MERGED_DIR="${WORKDIR}/merged-${ARCH}"
rm -rf "$MERGED_DIR"
mkdir -p "$MERGED_DIR"

log "静态合并 libunrar.a + unrar_shim.o..."
xcrun libtool -D -static -o "${MERGED_DIR}/UnRAR" \
    "$SHIM_OBJ" \
    "$LIBUNRAR_A" \
    || die "libtool 合并失败"

# --- 组 framework 骨架 -------------------------------------------------
FRAMEWORK_DIR="${WORKDIR}/UnRAR.framework"
rm -rf "$FRAMEWORK_DIR"
mkdir -p "${FRAMEWORK_DIR}/Headers" "${FRAMEWORK_DIR}/Modules"

cp "${SHIM_DIR}/unrar_shim.h" "${FRAMEWORK_DIR}/Headers/"
cp "${MERGED_DIR}/UnRAR" "${FRAMEWORK_DIR}/UnRAR"

# UnRAR 是 C++：必须 link "c++"；回调与线程池需要 pthread。
cat > "${FRAMEWORK_DIR}/Modules/module.modulemap" <<'EOF'
framework module UnRAR {
    header "unrar_shim.h"
    export *
    link "c++"
    link "pthread"
}
EOF
log "framework 骨架: ${FRAMEWORK_DIR}"

# --- xcodebuild -create-xcframework -------------------------------------
log "create-xcframework..."
rm -rf "$OUTPUT_PATH"
mkdir -p "$(dirname "$OUTPUT_PATH")"
xcodebuild -create-xcframework \
    -framework "$FRAMEWORK_DIR" \
    -output "$OUTPUT_PATH" \
    || die "create-xcframework 失败"

# --- 许可合规：复制 license.txt ----------------------------------------
LICENSE_DIR="${PROJECT_DIR}/Vendor/unrar-src"
mkdir -p "$LICENSE_DIR"
cp "$SRC_DIR/license.txt" "${LICENSE_DIR}/LICENSE"
log "许可副本: ${LICENSE_DIR}/LICENSE"

log "完成: $OUTPUT_PATH"

# --- 清理（保留 tarball 与源码目录做缓存；仅清临时 obj） ----------------
rm -f "$SHIM_OBJ"
if [[ "$KEEP_WORK" -eq 0 ]]; then
    rm -rf "$MERGED_DIR" "$FRAMEWORK_DIR"
    log "已清理临时产物（--keep-work 可保留 framework 骨架）"
fi

exit 0
