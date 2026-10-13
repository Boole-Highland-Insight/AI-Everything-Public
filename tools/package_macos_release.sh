#!/bin/bash
# Public distribution requires a real Developer ID identity and a stored notarytool profile.
set -euo pipefail
AIE_PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${AIE_SIGN_IDENTITY:-}" ] || [ -z "${AIE_NOTARY_PROFILE:-}" ]; then
  echo "公开发布尚未就绪：请设置 AIE_SIGN_IDENTITY（Developer ID Application）和 AIE_NOTARY_PROFILE（钥匙串公证配置名称）。" >&2
  exit 2
fi
case "$AIE_SIGN_IDENTITY" in
  "Developer ID Application:"*) ;;
  *) echo "公开下载包必须使用 Developer ID Application 证书。" >&2; exit 2 ;;
esac
if ! security find-identity -v -p codesigning | grep -F -- "$AIE_SIGN_IDENTITY" >/dev/null; then
  echo "钥匙串中没有此有效签名身份，请先安装证书及其私钥。" >&2
  exit 2
fi
if [ "${1:-}" = "--check" ]; then
  echo "签名配置已找到；公证账号与干净机器安装仍需正式打包时验证。"
  exit 0
fi
bash "$AIE_PROJECT/apps/macos/AIEPopup/build.sh"
AIE_APP="$AIE_PROJECT/apps/macos/AIEPopup/build/AI Everything.app"
AIE_VERSION_VALUE=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$AIE_APP/Contents/Info.plist")
AIE_ARCH_VALUE="${AIE_ARCH:-$(uname -m)}"
AIE_OUTPUT="$AIE_PROJECT/apps/macos/AIEPopup/build/releases"
mkdir -p "$AIE_OUTPUT"
AIE_STAGE="$(mktemp -d "$AIE_OUTPUT/.notary.XXXXXX")"
trap 'rm -rf "$AIE_STAGE"' EXIT
ditto -c -k --keepParent "$AIE_APP" "$AIE_STAGE/submission.zip"
xcrun notarytool submit "$AIE_STAGE/submission.zip" --keychain-profile "$AIE_NOTARY_PROFILE" \
  --wait --output-format json > "$AIE_STAGE/notarization.json"
if [ "$(/usr/bin/plutil -extract status raw -o - "$AIE_STAGE/notarization.json")" != "Accepted" ]; then
  cp "$AIE_STAGE/notarization.json" "$AIE_OUTPUT/last-notarization.json"
  echo "Apple 公证未通过，未生成公开下载包。状态保存在 releases/last-notarization.json。" >&2
  exit 1
fi
xcrun stapler staple "$AIE_APP"
xcrun stapler validate "$AIE_APP"
codesign --verify --deep --strict "$AIE_APP"
spctl --assess --type execute --verbose=2 "$AIE_APP"
AIE_ARCHIVE="$AIE_OUTPUT/AI-Everything-$AIE_VERSION_VALUE-$AIE_ARCH_VALUE.zip"
ditto -c -k --keepParent "$AIE_APP" "$AIE_ARCHIVE"
shasum -a 256 "$AIE_ARCHIVE" > "$AIE_ARCHIVE.sha256"
cp "$AIE_STAGE/notarization.json" "$AIE_OUTPUT/last-notarization.json"
echo "已签名并公证的下载包：$AIE_ARCHIVE"
