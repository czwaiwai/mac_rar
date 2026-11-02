#!/usr/bin/env bash
# =============================================================================
# build_dmg.sh — 将编译产出的 .app 打包为可分发的 .dmg
# =============================================================================
#
# 用法:
#   Scripts/build_dmg.sh [选项]
#
# 选项:
#   -a, --app <path>        .app 包路径。
#                           默认按以下顺序自动探测:
#                             1) dist/RARExtractor.app          (build_app.sh 默认产物)
#                             2) .build/release/RARExtractor.app
#                             3) .build/release/ 下第一个 *.app
#                             4) .build/debug/RARExtractor.app
#                             5) .build/debug/ 下第一个 *.app
#                           若仍未找到，自动调用 Scripts/build_app.sh 组装（见 --no-build-app）。
#   -o, --output <path>     输出 .dmg 路径。
#                           默认: dist/<AppName>-<CFBundleShortVersionString>.dmg
#   -n, --volume-name <name> dmg 挂载卷名。默认取 .app 的显示名。
#   --no-build-app          禁用「未找到 .app 时自动调用 build_app.sh」的行为。
#   --codesign <identity>    [预留] 签名身份（如 "Developer ID Application: ..."）。
#                           本阶段不实际签名，仅记录并打印后续调用提示。
#   --notarize               [预留] 启用公证流程。
#                           本阶段不实际公证，仅记录并打印后续调用提示。
#   --notary-profile <name>  [预留] notarytool 使用的 keychain profile。
#   --notary-team <team-id>  [预留] 公证使用的 Apple Developer Team ID。
#   -h, --help               显示本帮助。
#
# 示例:
#   swift build -c release && Scripts/build_app.sh && Scripts/build_dmg.sh
#   Scripts/build_dmg.sh
#   Scripts/build_dmg.sh -a /path/to/RARExtractor.app -o dist/RARExtractor.dmg
#   Scripts/build_dmg.sh --codesign "Developer ID Application: Foo (XXXX)" --notarize
#
# 依赖: hdiutil / plutil / (可选 build_app.sh、codesign、xcrun notarytool 供预留钩子)
# =============================================================================

set -euo pipefail

# --- 常量 ---------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_APP_NAME="RARExtractor"

# --- 变量 ---------------------------------------------------------------
APP_PATH=""
OUTPUT_PATH=""
VOLUME_NAME=""
CODESIGN_IDENTITY=""      # 预留
DO_NOTARIZE=0             # 预留
NOTARY_PROFILE=""         # 预留
NOTARY_TEAM=""            # 预留
NO_BUILD_APP=0

# --- 工具函数 -----------------------------------------------------------
usage() {
    sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
    printf '错误: %s\n' "$*" >&2
    exit 1
}

log() {
    printf '[build_dmg] %s\n' "$*"
}

# --- 参数解析 -----------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--app)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            APP_PATH="$2"; shift 2 ;;
        --app=*)
            APP_PATH="${1#*=}"; shift ;;
        -o|--output)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            OUTPUT_PATH="$2"; shift 2 ;;
        --output=*)
            OUTPUT_PATH="${1#*=}"; shift ;;
        -n|--volume-name)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            VOLUME_NAME="$2"; shift 2 ;;
        --volume-name=*)
            VOLUME_NAME="${1#*=}"; shift ;;
        --codesign)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            CODESIGN_IDENTITY="$2"; shift 2 ;;
        --codesign=*)
            CODESIGN_IDENTITY="${1#*=}"; shift ;;
        --notarize)
            DO_NOTARIZE=1; shift ;;
        --no-build-app)
            NO_BUILD_APP=1; shift ;;
        --notary-profile)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            NOTARY_PROFILE="$2"; shift 2 ;;
        --notary-profile=*)
            NOTARY_PROFILE="${1#*=}"; shift ;;
        --notary-team)
            [[ $# -gt 1 ]] || die "$1 需要一个参数"
            NOTARY_TEAM="$2"; shift 2 ;;
        --notary-team=*)
            NOTARY_TEAM="${1#*=}"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            die "未知选项: $1（-h/--help 查看帮助）" ;;
    esac
done

# --- 定位 .app ----------------------------------------------------------
if [[ -z "$APP_PATH" ]]; then
    # 探测顺序：dist（build_app.sh 默认产物）→ release → debug
    CANDIDATES=(
        "${PROJECT_DIR}/dist/${DEFAULT_APP_NAME}.app"
        "${PROJECT_DIR}/.build/release/${DEFAULT_APP_NAME}.app"
        "${PROJECT_DIR}/.build/debug/${DEFAULT_APP_NAME}.app"
    )
    for cand in "${CANDIDATES[@]}"; do
        if [[ -d "$cand" ]]; then
            APP_PATH="$cand"
            break
        fi
    done

    # 兜底：release/debug 目录下第一个 *.app
    if [[ -z "$APP_PATH" ]]; then
        for d in "${PROJECT_DIR}/.build/release" "${PROJECT_DIR}/.build/debug"; do
            [[ -d "$d" ]] || continue
            APP_PATH="$(find "$d" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -n 1 || true)"
            [[ -n "$APP_PATH" ]] && break
        done
    fi

    # 仍无：自动调用 build_app.sh 组装
    if [[ -z "$APP_PATH" ]]; then
        if [[ "$NO_BUILD_APP" -eq 1 ]]; then
            die "未找到 .app，且 --no-build-app 已禁用自动组装，请先运行 Scripts/build_app.sh"
        fi
        BUILD_APP="${SCRIPT_DIR}/build_app.sh"
        if [[ -x "$BUILD_APP" ]]; then
            log "未找到 .app，自动调用 build_app.sh 组装..."
            "$BUILD_APP"
            APP_PATH="${PROJECT_DIR}/dist/${DEFAULT_APP_NAME}.app"
        else
            die "未找到 .app 且缺少 Scripts/build_app.sh，请先组装或通过 -a/--app 指定路径"
        fi
    fi
    [[ -n "$APP_PATH" ]] || die "未找到 .app，请先编译并运行 Scripts/build_app.sh"
fi

[[ -d "$APP_PATH" ]] || die ".app 不存在: $APP_PATH"
[[ "$APP_PATH" == *.app ]] || die "路径不是 .app 包: $APP_PATH"

APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"
APP_BASENAME="$(basename "$APP_PATH" .app)"

# --- 元信息 -------------------------------------------------------------
PLIST="${APP_PATH}/Contents/Info.plist"
[[ -f "$PLIST" ]] || die "找不到 Info.plist: $PLIST"

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null || echo "0.0.0")"
[[ -z "$VOLUME_NAME" ]] && VOLUME_NAME="$APP_BASENAME"
[[ -z "$OUTPUT_PATH" ]] && OUTPUT_PATH="${PROJECT_DIR}/dist/${APP_BASENAME}-${APP_VERSION}.dmg"

OUTPUT_DIR="$(dirname "$OUTPUT_PATH")"
mkdir -p "$OUTPUT_DIR"
OUTPUT_PATH="$(cd "$OUTPUT_DIR" && pwd)/$(basename "$OUTPUT_PATH")"

STAGING_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGING_DIR"' EXIT

log "app:          ${APP_PATH}"
log "版本:         ${APP_VERSION}"
log "输出 dmg:     ${OUTPUT_PATH}"
log "卷名:         ${VOLUME_NAME}"
if [[ -n "$CODESIGN_IDENTITY" ]]; then
    log "[预留] 签名身份: ${CODESIGN_IDENTITY}"
fi
if [[ "$DO_NOTARIZE" -eq 1 ]]; then
    log "[预留] 公证: 已启用（profile=${NOTARY_PROFILE:-未指定}, team=${NOTARY_TEAM:-未指定}）"
fi

# --- 组装 staging（.app + /Applications 软链接）-------------------------
log "组装 staging 目录..."
cp -R "$APP_PATH" "${STAGING_DIR}/"
ln -s /Applications "${STAGING_DIR}/Applications"

# --- 创建 dmg -----------------------------------------------------------
# 直接一步生成 UDZO 压缩只读镜像。
# （原两段式 UDRW→convert 会在本机 hdiutil 挂载 UDRW 时触发 ENOSPC，改用一步到位。）
log "创建 UDZO 压缩 dmg（hdiutil create -srcfolder）..."
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT_PATH" >/dev/null

log "完成: ${OUTPUT_PATH}"

# --- 预留钩子: 签名与公证（本阶段不实际执行）-----------------------------
if [[ -n "$CODESIGN_IDENTITY" ]]; then
    cat <<EOF

[预留] 后续签名（当前未执行）:
  codesign --force --deep --options runtime \\
    --sign "${CODESIGN_IDENTITY}" \\
    "${APP_PATH}"
EOF
fi

if [[ "$DO_NOTARIZE" -eq 1 ]]; then
    PROFILE_ARG=""
    [[ -n "$NOTARY_PROFILE" ]] && PROFILE_ARG="--keychain-profile ${NOTARY_PROFILE}"
    TEAM_ARG=""
    [[ -n "$NOTARY_TEAM" ]] && TEAM_ARG="--team-id ${NOTARY_TEAM}"
    cat <<EOF

[预留] 后续公证（当前未执行，需先完成签名）:
  xcrun notarytool submit "${OUTPUT_PATH}" ${PROFILE_ARG} ${TEAM_ARG} --wait
  xcrun stapler staple "${OUTPUT_PATH}"
EOF
fi

exit 0
