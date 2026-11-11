#!/bin/bash
# Jellyfish AI を .app にまとめる。Xcode 不要（Command Line Tools の swift だけで完結）。
#   scripts/build.sh            release ビルド → dist/JellyfishAI.app
#   scripts/build.sh debug      debug ビルド
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${1:-release}"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/JellyfishAI"

APP="$ROOT/dist/JellyfishAI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/JellyfishAI"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# アイコンはクラゲのレンダラ自身で描く
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
"$BIN" --icon "$TMP/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

# アドホック署名（ローカル実行用）
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built: $APP"
