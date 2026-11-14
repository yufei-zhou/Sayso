#!/bin/bash
# Installs Sayso, or updates it to the latest release:
#   curl -fsSL https://raw.githubusercontent.com/yufei-zhou/Sayso/main/install.sh | bash
set -euo pipefail

REPO="yufei-zhou/Sayso"
APP_NAME="Sayso.app"
ASSET="Sayso.zip"
# Every release is signed with this certificate. A download signed any other way is refused, and because the
# signature never changes, macOS keeps the Accessibility and Input Monitoring permissions across updates.
REQUIREMENT='identifier "local.nano.Sayso" and certificate leaf = H"7b929abdbae42f2f2a63141dee5e4b223c127742"'

DIR="${INSTALL_DIR:-/Applications}"
if [ ! -w "${DIR}" ]; then
  DIR="$HOME/Applications"
  mkdir -p "${DIR}"
fi
TARGET="${DIR}/$APP_NAME"

# /releases/latest redirects to the newest release's tag.
latest_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")
tag="${latest_url##*/}"
version="${tag#v}"
if [[ ! "$tag" =~ ^v[0-9] ]]; then
  echo "找不到可用的版本。" >&2
  exit 1
fi

installed=""
if [ -d "$TARGET" ]; then
  installed=$(defaults read "$TARGET/Contents/Info" CFBundleShortVersionString 2>/dev/null || true)
fi
if [ "${installed}" = "${version}" ]; then
  echo "Sayso 已是最新版本（${version}）。"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "正在下载 Sayso ${version}…"
curl -fsSL -o "$tmp/$ASSET" "https://github.com/$REPO/releases/download/$tag/$ASSET"
ditto -x -k "$tmp/$ASSET" "$tmp"
if ! codesign --verify --strict -R="$REQUIREMENT" "$tmp/$APP_NAME" 2>/dev/null; then
  echo "签名校验失败，已取消安装。" >&2
  exit 1
fi

pkill -x Sayso 2>/dev/null && sleep 1 || true
rm -rf "$TARGET"
ditto "$tmp/$APP_NAME" "$TARGET"
# curl doesn't mark downloads as quarantined, but clear it in case anything did.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

if [ -n "${installed}" ]; then
  echo "已从 ${installed} 更新到 ${version}。"
else
  echo "已安装 Sayso ${version} 到 ${DIR}。"
  echo "第一次打开时请按提示在「系统设置 → 隐私与安全性」里允许「辅助功能」和「输入监控」，再在设置窗口里填入 OpenAI API Key。"
fi
if [ "${NO_LAUNCH:-}" != 1 ]; then
  open "$TARGET"
fi
