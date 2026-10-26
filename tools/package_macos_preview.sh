#!/bin/bash
# Explicitly unnotarized preview for GitHub Releases; signed releases use package_macos_release.sh.
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
AIE_RELEASE="${AIE_RELEASE:-0.1.0}"
AIE_ARCH_VALUE="${AIE_ARCH:-$(uname -m)}"
case "$AIE_RELEASE" in *[!a-zA-Z0-9.-]*|'') echo 'Invalid release version' >&2; exit 2;; esac
case "$AIE_ARCH_VALUE" in arm64|x86_64) ;; *) echo 'Unsupported architecture' >&2; exit 2;; esac
bash "$AIE_PROJECT/apps/macos/AIEPopup/build.sh"
AIE_APP="$AIE_PROJECT/apps/macos/AIEPopup/build/AI Everything.app"
AIE_OUTPUT="$AIE_PROJECT/apps/macos/AIEPopup/build/releases"
mkdir -p "$AIE_OUTPUT"
AIE_STAGE="$(mktemp -d "$AIE_OUTPUT/.preview.XXXXXX")"
trap 'rm -rf "$AIE_STAGE"' EXIT
ditto --noextattr --norsrc "$AIE_APP" "$AIE_STAGE/AI Everything.app"
codesign --verify --deep --strict "$AIE_STAGE/AI Everything.app"
ln -s /Applications "$AIE_STAGE/Applications"
cp "$AIE_PROJECT/LICENSE" "$AIE_STAGE/LICENSE.txt"
cat > "$AIE_STAGE/安装说明.txt" <<'GUIDE'
AI Everything · 未公证版本

1. 将 AI Everything 拖到旁边的 Applications（应用程序）。
2. 从应用程序文件夹打开。首次引导中选择要搜索的资料夹与本机模型。
3. 按 Option + Space 唤起搜索；右上角可查看扫描进度、配置云端与打开「咔哒一下」。

此版本使用 ad-hoc 签名，尚无 Developer ID 签名或 Apple 公证。
如 macOS 提示无法验证开发者，请先核对下载来源和 SHA256SUMS。
确认信任后，可在「系统设置 → 隐私与安全性」中为此应用点「仍要打开」。
不要关闭系统的全局安全检查。受管理设备可能不允许添加此例外。

EmbeddingGemma 2 向量模型已包含在 App 内；Qwen3-VL 内容理解模型按所选方案单独下载。
本机搜索不需要 API Key。云端自动精排与「咔哒一下」需要自备 OpenRouter Key，并会发送相应内容。
原件默认保留；只有你主动选择的文件才会移入应用垃圾桶。

下载、安装说明、隐私边界与问题反馈：
https://github.com/Boole-Highland-Insight/AI-Everything-Public
GUIDE
AIE_DMG="$AIE_OUTPUT/AI-Everything-$AIE_RELEASE-$AIE_ARCH_VALUE.dmg"
hdiutil create -volname 'AI Everything' -srcfolder "$AIE_STAGE" -ov -format UDZO -fs HFS+ "$AIE_DMG"
hdiutil verify "$AIE_DMG"
(cd "$AIE_OUTPUT" && LC_ALL=C shasum -a 256 "$(basename "$AIE_DMG")" > SHA256SUMS)
echo "未公证版本：$AIE_DMG"
