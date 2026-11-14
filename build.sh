#!/bin/bash
# Builds Sayso.app for Apple silicon and Intel. `./build.sh install` also copies it to /Applications and (re)starts it
# in the background. REQUIRE_SIGNING=1 (used by release.sh) refuses to fall back to an unsigned build.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Sayso.app"
SIGN_ID="${SIGN_ID:-ClairRoute Local Development}"
PROMPTS="${PROMPTS_SRC:-prompts}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Sayso"
mkdir -p build
if [ ! -f build/AppIcon.icns ] || [ Scripts/make_icon.swift -nt build/AppIcon.icns ]; then
  rm -rf build/AppIcon.iconset && mkdir -p build/AppIcon.iconset
  swift Scripts/make_icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/prompts"
cp "$BIN" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp build/AppIcon.icns "$APP/Contents/Resources/"
cp "$PROMPTS"/*.md "$APP/Contents/Resources/prompts/"
# A stable signing identity keeps the Input Monitoring, Accessibility and Keychain grants valid across rebuilds.
if security find-identity -v -p codesigning | grep -q "$SIGN_ID"; then
  codesign --force --sign "$SIGN_ID" --identifier local.nano.Sayso "$APP"
elif [ "${REQUIRE_SIGNING:-}" = 1 ]; then
  echo "The \"$SIGN_ID\" certificate isn't in the Keychain; a release must be signed with it." >&2
  exit 1
else
  codesign --force --sign - --identifier local.nano.Sayso "$APP"
fi

if [ "${1:-}" = "install" ]; then
  pkill -x Sayso || true
  sleep 0.5
  rm -rf /Applications/Sayso.app
  cp -R "$APP" /Applications/
  open -g /Applications/Sayso.app
fi
echo "Built $APP"
