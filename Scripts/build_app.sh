#!/usr/bin/env bash
# =============================================================================
# build_app.sh — 将 SPM 产出的裸二进制组装为标准 macOS .app bundle
# =============================================================================
#
# 用法:
#   Scripts/build_app.sh [选项]
#
# 说明:
#   SPM executable target 只产出裸二进制（如 .build/release/RARExtractor），
#   本脚本把它组装成可被 Launch Services / Finder 识别的 .app 包：
#
#     RARExtractor.app/
#     └── Contents/
#         ├── Info.plist            ← 复制自 Resources/Info.plist
#         ├── PkgInfo               ← 固定 "APPL????"
#         ├── MacOS/RARExtractor    ← 裸二进制
#         └── Resources/            ← Resources/ 目录内容（图标等，Info.plist 除外）
#
# 选项:
#   -e, --executable <path>  裸二进制路径。
#                            默认按以下顺序自动探测:
#                              1) .build/release/RARExtractor
#                              2) .build/debug/RARExtractor
#   -o, --output <path>      .app 输出路径。默认 dist/RARExtractor.app
#   --info-plist <path>      Info.plist 来源。默认 Resources/Info.plist
#   --no-sign                跳过 ad-hoc 签名（默认会 codesign --force --deep --sign -）
#   -h, --help               显示本帮助。
#
# 示例:
#   swift build -c release
#   Scripts/build_app.sh                    # 自动探测 release 二进制并组装
#   Scripts/build_app.sh --no-sign          # 组装但不签名
#
# 依赖: plutil / codesign（ad-hoc 签名，无需开发者账号）
# =============================================================================

set -euo pipefail

# --- 常量 ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_EXE_NAME="RARExtractor"

# --- 变量 ---------------------------------------------------------------
EXE_PATH=""
OUTPUT_PATH=""
INFO_PLIST=""
DO_SIGN=1   # 默认做 ad-hoc 签名

# --- 工具函数 -----------------------------------------------------------
usage() {
    sed -n '2,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[build_app] %s\n' "$*"
}

warn() {
    printf '[build_app][警告] %s\n' "$*" >&2
}

# --- 参数解析 -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--executable)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            EXE_PATH="$2"; shift 2 ;;
        --executable=*)
            EXE_PATH="${1#*=}"; shift ;;
        -o|--output)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            OUTPUT_PATH="$2"; shift 2 ;;
        --output=*)
            OUTPUT_PATH="${1#*=}"; shift ;;
        --info-plist)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            INFO_PLIST="$2"; shift 2 ;;
        --info-plist=*)
            INFO_PLIST="${1#*=}"; shift ;;
        --no-sign)
            DO_SIGN=0; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "未知选项: $1（-h/--help 查看帮助）" ;;
    esac
done

# --- 定位裸二进制 -------------------------------------------------------
if [[ -z "$EXE_PATH" ]]; then
    for cand in \
        "${PROJECT_DIR}/.build/release/${DEFAULT_EXE_NAME}" \
        "${PROJECT_DIR}/.build/debug/${DEFAULT_EXE_NAME}"; do
        if [[ -x "$cand" ]]; then
            EXE_PATH="$cand"
            break
        fi
    done
    [[ -n "$EXE_PATH" ]] || die "未找到裸二进制（${DEFAULT_EXE_NAME}），请先 swift build -c release，或通过 -e/--executable 指定"
fi

[[ -f "$EXE_PATH" && -x "$EXE_PATH" ]] || die "二进制不存在或不可执行: $EXE_PATH"
EXE_PATH="$(cd "$(dirname "$EXE_PATH")" && pwd)/$(basename "$EXE_PATH")"
EXE_NAME="$(basename "$EXE_PATH")"

# --- 定位 Info.plist ----------------------------------------------------
[[ -n "$INFO_PLIST" ]] || INFO_PLIST="${PROJECT_DIR}/Resources/Info.plist"
[[ -f "$INFO_PLIST" ]] || die "找不到 Info.plist: $INFO_PLIST"
INFO_PLIST="$(cd "$(dirname "$INFO_PLIST")" && pwd)/$(basename "$INFO_PLIST")"

# --- 输出路径 -----------------------------------------------------------
[[ -n "$OUTPUT_PATH" ]] || OUTPUT_PATH="${PROJECT_DIR}/dist/${EXE_NAME}.app"
[[ "$OUTPUT_PATH" == *.app ]] || die "输出路径必须是 .app 包: $OUTPUT_PATH"

# --- 组装 bundle --------------------------------------------------------
OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"
APP_DIR="$(cd "$OUTPUT_DIR" && pwd)/$(basename "$OUTPUT_PATH")"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

log "裸二进制:   ${EXE_PATH}"
log "Info.plist:  ${INFO_PLIST}"
log "输出 .app:  ${APP_DIR}"

# 幂等：先清掉旧产物再重建，避免残留
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# 1) 二进制
cp "$EXE_PATH" "${MACOS_DIR}/${EXE_NAME}"
chmod +x "${MACOS_DIR}/${EXE_NAME}"

# 2) Info.plist
cp "$INFO_PLIST" "${CONTENTS_DIR}/Info.plist"

# 3) PkgInfo（标准 "APPL????"）
printf 'APPL????' > "${CONTENTS_DIR}/PkgInfo"

# 4) Resources：复制 Resources/ 下除 Info.plist 外的所有内容（图标、本地化等）
INFO_DIR="$(dirname "$INFO_PLIST")"
if [[ -d "$INFO_DIR" ]]; then
    find "$INFO_DIR" -mindepth 1 -maxdepth 1 \
        ! -name 'Info.plist' \
        -exec cp -R {} "$RESOURCES_DIR/" \; 2>/dev/null || true
fi

# --- 校验 Info.plist ----------------------------------------------------
if ! plutil -lint "${CONTENTS_DIR}/Info.plist" >/dev/null; then
    rm -rf "$APP_DIR"
    die "Info.plist 校验失败: ${CONTENTS_DIR}/Info.plist"
fi
log "Info.plist 校验通过"

# 校验 CFBundleExecutable 与二进制名一致（不一致仅告警，不中断）
PLIST_EXE="$(plutil -extract CFBundleExecutable raw "${CONTENTS_DIR}/Info.plist" 2>/dev/null || true)"
if [[ -n "$PLIST_EXE" && "$PLIST_EXE" != "$EXE_NAME" ]]; then
    warn "Info.plist 的 CFBundleExecutable=${PLIST_EXE} 与二进制名 ${EXE_NAME} 不一致，请检查"
fi

# --- ad-hoc 签名 --------------------------------------------------------
if [[ "$DO_SIGN" -eq 1 ]]; then
    if command -v codesign >/dev/null 2>&1; then
        log "执行 ad-hoc 签名（codesign --force --deep --sign -）..."
        codesign --force --deep --sign - "$APP_DIR"
        log "ad-hoc 签名完成"
    else
        warn "未找到 codesign，跳过签名"
    fi
else
    log "已跳过 ad-hoc 签名（--no-sign）"
fi

# --- 结果展示 -----------------------------------------------------------
log "完成: ${APP_DIR}"
echo
echo "bundle 结构:"
find "$APP_DIR" -maxdepth 4 -print | sed "s|${APP_DIR}|RARExtractor.app|" | sort

exit 0
