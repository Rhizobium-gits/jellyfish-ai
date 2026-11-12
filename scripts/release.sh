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
scripts/build.sh --universal --sign

APP="dist/JellyfishAI.app"
codesign --verify --strict --verbose=2 "$APP"
# grep -q に直接つなぐと、pipefail のもとで codesign が SIGPIPE で失敗扱いになることがあるので、いったん変数に受ける
SIG="$(codesign -d --verbose=2 "$APP" 2>&1)"
[[ "$SIG" =~ flags=[^[:space:]]*runtime ]] || { echo "Hardened Runtime が付いていません" >&2; exit 1; }
ARCHS="$(lipo -archs "$APP/Contents/MacOS/JellyfishAI")"
[[ "$ARCHS" == *arm64* && "$ARCHS" == *x86_64* ]] || { echo "universal ではありません: $ARCHS" >&2; exit 1; }

OUT="dist/release"
rm -rf "$OUT"
mkdir -p "$OUT"
# .dmg はどの版も同じ名前にする：README の「ダウンロード」を releases/latest/download/JellyfishAI.dmg への直リンクにでき、
# GitHub のダウンロード数もこの 1 つで数えられる（scripts/downloads.sh）。.zip は版つき（アプリのアップデートが版で選ぶ）
DMG="$OUT/JellyfishAI.dmg"
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

1. \`JellyfishAI.dmg\` を開き、JellyfishAI を Applications へドラッグ
2. 初回だけ macOS が起動を止めます（Apple の公証を受けていないため）。ダイアログを閉じ、**システム設定 › プライバシーとセキュリティ** の「このまま開く」で許可してください
3. 使う AI（Claude Code・Codex CLI・Gemini CLI のどれか）にログインします。初めて開いたときの「アカウントと AI」の画面から、入っていないものは許可すれば入れてそのままログインできます

エージェントは確認なしでファイルの作成・編集やコマンドの実行を行い（Claude Code の Auto モード）、あなたの Claude Code の使用量を消費します。新しい版に入れ替えたときは、画面収録・アクセシビリティの許可をもう一度求められることがあります。

macOS 14 以降・Apple シリコン / Intel 両対応（universal）。チェックサムは SHA256SUMS.txt。

### Install (English)

1. Open \`JellyfishAI.dmg\` and drag JellyfishAI to Applications
2. macOS blocks the first launch because the app is not notarized. Close the dialog and click **Open Anyway** in **System Settings › Privacy & Security**
3. Sign in to the AI you use (Claude Code, Codex CLI or Gemini CLI). The “Accounts & AI” screen shown at first launch can also install a missing one, once you allow it, and start its sign-in

Agents edit files and run commands without asking (Claude Code Auto mode) and use your Claude Code usage. Switch the display language from the menu bar jellyfish › 🌐 Language. See [README.en.md](https://github.com/Rhizobium-gits/jellyfish-ai/blob/main/README.en.md).

### 安装（简体中文）

1. 打开 \`JellyfishAI.dmg\`，把 JellyfishAI 拖到“应用程序”
2. 由于没有经过 Apple 公证，首次打开会被 macOS 阻止。关闭对话框后，在 **系统设置 › 隐私与安全性** 中点击 **仍要打开**
3. 登录要使用的 AI（Claude Code、Codex CLI 或 Gemini CLI 之一）。首次打开时的“账户与 AI”界面中，未安装的也可以在你允许后安装并直接登录

智能体会在不经确认的情况下编辑文件、执行命令（Claude Code 的 Auto 模式），并消耗你的 Claude Code 用量。可以在菜单栏的水母 › 🌐 语言 中切换显示语言。详见 [README.zh-CN.md](https://github.com/Rhizobium-gits/jellyfish-ai/blob/main/README.zh-CN.md)。
NOTE

ls -la "$OUT"
cat "$OUT/SHA256SUMS.txt"

if [[ $PUBLISH == 1 ]]; then
  gh release create "$TAG" "$DMG" "$ZIP" "$OUT/SHA256SUMS.txt" \
    --target "$(git rev-parse HEAD)" --title "Jellyfish AI $VERSION" --notes-file "$NOTES"
fi
