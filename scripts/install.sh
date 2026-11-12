#!/bin/bash
# この Mac で Jellyfish AI を普通のアプリとして使えるようにする（毎回ターミナルから起動しなくてよくなる）。
#   scripts/install.sh              ビルドして「アプリケーション」フォルダに入れ、起動する
#   scripts/install.sh --no-build   いまの dist/JellyfishAI.app をそのまま入れる
# 入れたあとは Launchpad・Spotlight・Finder の「アプリケーション」から開ける。Dock に置くこともできる。
# 入れる先は /Applications（書き込めなければ ~/Applications）。dist/ の .app は移すので、同じアプリが 2 つ並ばない。
# 動いている Jellyfish AI は終えてから入れ替える（作業中のエージェントがいるときは何もしない）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
BUILD=1
for a in "$@"; do
  case "$a" in
    --no-build) BUILD=0 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done

BUNDLE_ID=ai.jellyfish.desktop
SRC="$ROOT/dist/JellyfishAI.app"
DEST_DIR=/Applications
[[ -w "$DEST_DIR" ]] || { DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; }
DEST="$DEST_DIR/JellyfishAI.app"

bundle_id() { /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$1/Contents/Info.plist" 2>/dev/null || true; }

running_busy() {
  # エージェントが動いている間は claude などがアプリの子プロセスとしている
  local p
  for p in $(pgrep -x JellyfishAI || true); do
    pgrep -P "$p" >/dev/null && return 0
  done
  return 1
}

# ビルドに数分かかることがあるので、作業中ならビルドの前に止める
if running_busy; then
  echo "作業中のエージェントがいるので、入れ替えをやめました。終わってからもう一度実行してください。" >&2
  exit 1
fi

[[ $BUILD == 1 ]] && scripts/build.sh
[[ "$(bundle_id "$SRC")" == "$BUNDLE_ID" ]] || { echo "$SRC がありません（scripts/build.sh でビルドしてください）" >&2; exit 1; }
# 入れ替える先に別のアプリがあれば触らない
if [[ -e "$DEST" && "$(bundle_id "$DEST")" != "$BUNDLE_ID" ]]; then
  echo "$DEST は Jellyfish AI ではないので、上書きしません。" >&2
  exit 1
fi

# 動いている Jellyfish AI を終える（終了の処理で、クラゲの位置などを保存してから終わる）
if pgrep -x JellyfishAI >/dev/null; then
  if running_busy; then
    echo "作業中のエージェントがいるので、入れ替えをやめました。終わってからもう一度実行してください（ビルドは dist/ に残っています。--no-build で入れられます）。" >&2
    exit 1
  fi
  pkill -x JellyfishAI || true
  for _ in $(seq 100); do pgrep -x JellyfishAI >/dev/null || break; /bin/sleep 0.1; done
  if pgrep -x JellyfishAI >/dev/null; then
    echo "Jellyfish AI が終わらないので、入れ替えをやめました。メニューバーのクラゲから終了してから、もう一度実行してください。" >&2
    exit 1
  fi
fi

rm -rf "$DEST"
mv "$SRC" "$DEST"
open -g "$DEST"

echo "Installed: $DEST  (v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist"))"
echo "  ・Launchpad・Spotlight（⌘Space で「Jellyfish」）・Finder の「アプリケーション」から開けます。"
echo "    Dock に置くなら、アプリケーションフォルダの Jellyfish AI を Dock へドラッグしてください。"
echo "  ・動いているときにアイコンを開くと、隠したクラゲを出します（1 体もいなければ新しいクラゲを出します）。"
echo "  ・PC 操作・画面の添付を使っているなら、システム設定 › プライバシーとセキュリティ の「アクセシビリティ」"
echo "    「画面収録」で Jellyfish AI をいったん外して（−）、もう一度許可してください（アドホック署名のため、"
echo "    ビルドし直すと macOS は別のアプリとみなします）。"
settings="$HOME/Library/Application Support/JellyfishAI/settings.json"
if [[ "$(plutil -extract launchAtLogin raw "$settings" 2>/dev/null || true)" == "true" ]]; then
  echo "  ・アプリの場所が変わったので、ログイン時に起動しなくなっていたら、メニューバーのクラゲ ›"
  echo "    「ログイン時に自動起動」を一度オフにしてからオンにしてください。"
fi
