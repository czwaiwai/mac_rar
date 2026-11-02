#!/usr/bin/env bash
# =============================================================================
# register_ls.sh — 手动向 Launch Services 注册 .app，刷新文件关联
# =============================================================================
#
# 用法:
#   Scripts/register_ls.sh [<app 路径>]
#
#   不传参数时，自动探测:
#     1) .build/release/RARExtractor.app
#     2) .build/release/ 下第一个 *.app
#
# 说明:
#   开发期改了 CFBundleDocumentTypes / LSItemContentTypes 后，
#   macOS 可能不会立刻刷新文件关联。运行本脚本可强制
#   Launch Services 重新注册，立即生效。
#
# 依赖: lsregister（系统自带，位于 /System/Library/Frameworks/.../lsregister）
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_APP_NAME="RARExtractor"

APP_PATH="${1:-}"

if [[ -z "$APP_PATH" ]]; then
    RELEASE_DIR="${PROJECT_DIR}/.build/release"
    CANDIDATE="${RELEASE_DIR}/${DEFAULT_APP_NAME}.app"
    if [[ -d "$CANDIDATE" ]]; then
        APP_PATH="$CANDIDATE"
    elif [[ -d "$RELEASE_DIR" ]]; then
        APP_PATH="$(find "$RELEASE_DIR" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -n 1 || true)"
    fi
fi

[[ -n "$APP_PATH" ]] || { echo "错误: 未找到 .app，请编译或指定路径" >&2; exit 1; }
[[ -d "$APP_PATH" ]] || { echo "错误: .app 不存在: $APP_PATH" >&2; exit 1; }

APP_PATH="$(cd "$(dirname "$APP_PATH")" && pwd)/$(basename "$APP_PATH")"

LSREGISTER="$(find /System/Library/Frameworks -name lsregister -type f 2>/dev/null | head -n 1 || true)"
[[ -n "$LSREGISTER" ]] || LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[[ -x "$LSREGISTER" ]] || { echo "错误: 找不到可执行的 lsregister" >&2; exit 1; }

echo "注册: ${APP_PATH}"
"$LSREGISTER" -f "$APP_PATH"
echo "完成。"
