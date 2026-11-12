#!/bin/bash
# Jellyfish AI を .app にまとめる。Xcode 不要（Command Line Tools の swift だけで完結）。
#   scripts/build.sh                  release ビルド（この Mac の CPU 用）→ dist/JellyfishAI.app
#   scripts/build.sh debug            debug ビルド
#   scripts/build.sh --universal      Apple シリコン + Intel の両方で動く .app（配布用）
# バージョンは VERSION ファイル、ビルド番号は git のコミット数から入れる。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG=release
UNIVERSAL=0
for a in "$@"; do
  case "$a" in
    release|debug) CONFIG="$a" ;;
    --universal) UNIVERSAL=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

APP="$ROOT/dist/JellyfishAI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [[ $UNIVERSAL == 1 ]]; then
  bins=()
  for arch in arm64 x86_64; do
    swift build -c "$CONFIG" --arch "$arch"
    bins+=("$(swift build -c "$CONFIG" --arch "$arch" --show-bin-path)/JellyfishAI")
  done
  lipo -create "${bins[@]}" -output "$APP/Contents/MacOS/JellyfishAI"
  # アイコン描画はこの Mac の CPU 用のバイナリで
  NATIVE="$(swift build -c "$CONFIG" --arch "$(uname -m)" --show-bin-path)/JellyfishAI"
else
  swift build -c "$CONFIG"
  NATIVE="$(swift build -c "$CONFIG" --show-bin-path)/JellyfishAI"
  cp "$NATIVE" "$APP/Contents/MacOS/JellyfishAI"
fi

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

# アイコンはクラゲのレンダラ自身で描く
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
"$NATIVE" --icon "$TMP/icon_1024.png"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

# アドホック署名（Apple の開発者証明書なし。配布物は初回だけ「このまま開く」が必要）
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built: $APP  (v$VERSION build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/JellyfishAI"))"
