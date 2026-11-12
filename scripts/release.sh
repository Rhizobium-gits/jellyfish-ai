#!/bin/bash
# 配布物を作る：dist/release/ に .dmg・.zip・SHA256SUMS.txt・リリースノート
#   scripts/release.sh             作るだけ
#   scripts/release.sh --publish   作ったうえで GitHub Releases に v<VERSION> として公開する（gh が必要）
#
# 手順：VERSION と CHANGELOG.md の「## [x.y.z]」を更新 → コミット → push → scripts/release.sh --publish
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PUBLISH=0
[[ "${1:-}" == "--publish" ]] && PUBLISH=1

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
grep -q "^## \[$VERSION\]" CHANGELOG.md || { echo "CHANGELOG.md に ## [$VERSION] がありません" >&2; exit 1; }

if [[ $PUBLISH == 1 ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "コミットしていない変更があります" >&2; exit 1; }
  git fetch -q origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] || { echo "HEAD が push されていません" >&2; exit 1; }
  if gh release view "$TAG" >/dev/null 2>&1; then echo "$TAG はもうリリースされています" >&2; exit 1; fi
fi

scripts/test.sh
scripts/build.sh --universal

APP="dist/JellyfishAI.app"
codesign --verify --strict --verbose=2 "$APP"
ARCHS="$(lipo -archs "$APP/Contents/MacOS/JellyfishAI")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "universal ではありません: $ARCHS" >&2; exit 1; }

OUT="dist/release"
rm -rf "$OUT"
mkdir -p "$OUT"
DMG="$OUT/JellyfishAI-$VERSION.dmg"
ZIP="$OUT/JellyfishAI-$VERSION.zip"

# .dmg：アプリ・Applications へのリンク・はじめにお読みください
STAGE="$(mktemp -d)/Jellyfish AI"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp "Resources/dmg/はじめにお読みください.txt" "$STAGE/"
hdiutil create -quiet -volname "Jellyfish AI $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$(dirname "$STAGE")"
hdiutil verify -quiet "$DMG"

# .zip：アプリだけ（ditto で拡張属性ごと固める）
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" > SHA256SUMS.txt)

# リリースノート：CHANGELOG の該当節 + インストールの注意
NOTES="$OUT/notes.md"
awk -v v="$VERSION" '
  $0 ~ "^## \\[" v "\\]" { on = 1; next }
  on && /^## \[/ { exit }
  on && /^\[[0-9.]+\]: / { next }
  on { print }
' CHANGELOG.md > "$NOTES"
cat >> "$NOTES" <<NOTE

---

### インストール

1. \`JellyfishAI-$VERSION.dmg\` を開き、JellyfishAI を Applications へドラッグ
2. 初回だけ macOS が起動を止めます（Apple の公証を受けていないため）。ダイアログを閉じ、**システム設定 › プライバシーとセキュリティ** の「このまま開く」で許可してください
3. 先に [Claude Code](https://code.claude.com/docs/en/setup) をインストールしてログインしておく必要があります

エージェントは確認なしでファイルの作成・編集やコマンドの実行を行い（Claude Code の Auto モード）、あなたの Claude Code の使用量を消費します。新しい版に入れ替えたときは、画面収録・アクセシビリティの許可をもう一度求められることがあります。

macOS 14 以降・Apple シリコン / Intel 両対応（universal）。チェックサムは SHA256SUMS.txt。
NOTE

ls -la "$OUT"
cat "$OUT/SHA256SUMS.txt"

if [[ $PUBLISH == 1 ]]; then
  gh release create "$TAG" "$DMG" "$ZIP" "$OUT/SHA256SUMS.txt" \
    --target "$(git rev-parse HEAD)" --title "Jellyfish AI $VERSION" --notes-file "$NOTES"
fi
