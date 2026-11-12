#!/bin/bash
# Jellyfish AI を .app にまとめる。Xcode 不要（Command Line Tools の swift だけで完結）。
#   scripts/build.sh                  release ビルド（この Mac の CPU 用）→ dist/JellyfishAI.app
#   scripts/build.sh debug            debug ビルド
#   scripts/build.sh --universal      Apple シリコン + Intel の両方で動く .app（配布用）
#   scripts/build.sh --sign           scripts/signing.sh で作った証明書で署名する（無ければアドホック署名）。
#                                     同じ証明書なら、ビルドし直しても macOS の許可（フォルダ・アクセシビリティ・画面収録）が続く
# バージョンは VERSION ファイル、ビルド番号は git のコミット数から入れる。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG=release
UNIVERSAL=0
SIGN=0
for a in "$@"; do
  case "$a" in
    release|debug) CONFIG="$a" ;;
    --universal) UNIVERSAL=1 ;;
    --sign) SIGN=1 ;;
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

# アイコン：Resources/AppIcon.png（正方形の絵）を macOS のアイコンの角丸の枠に収める。無ければクラゲのドット絵を描く
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
ICON_ARGS=()
[[ -f "$ROOT/Resources/AppIcon.png" ]] && ICON_ARGS=(--icon-source "$ROOT/Resources/AppIcon.png")
"$NATIVE" --icon "$TMP/icon_1024.png" "${ICON_ARGS[@]+"${ICON_ARGS[@]}"}"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d "$TMP/icon_1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$TMP"

# 署名（Apple の開発者証明書なし。配布物は初回だけ「このまま開く」が必要）。
# Hardened Runtime を付ける：このアプリはアクセシビリティ・画面収録の許可を持つので、DYLD_INSERT_LIBRARIES などで
# 他のプログラムがこのプロセスに入り込み、その許可を使うことを OS に止めてもらう（追加の entitlement は無し）
# --sign：scripts/signing.sh の証明書で署名する（macOS が署名のたびに確認する）。無い・使えないときはアドホック署名
IDENTITY="${JELLYFISH_SIGN_IDENTITY:-Jellyfish AI Local Signing}"
SIGNED_WITH="ad-hoc"
if [[ $SIGN == 1 ]] && security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  if codesign --force --options runtime --sign "$IDENTITY" --timestamp=none "$APP" >/dev/null 2>&1; then
    SIGNED_WITH="$IDENTITY"
  else
    echo "「${IDENTITY}」で署名できませんでした（キーの確認を拒否した？）。アドホック署名にします" >&2
  fi
elif [[ $SIGN == 1 ]]; then
  echo "署名用の証明書「${IDENTITY}」がありません（scripts/signing.sh create で作れます）。アドホック署名にします" >&2
fi
[[ "$SIGNED_WITH" == "ad-hoc" ]] && codesign --force --options runtime --sign - --timestamp=none "$APP" >/dev/null
echo "Built: $APP  (v$VERSION build $BUILD_NUMBER, $(lipo -archs "$APP/Contents/MacOS/JellyfishAI"), signed: $SIGNED_WITH)"
