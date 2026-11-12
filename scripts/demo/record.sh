#!/bin/zsh
# README の GIF を撮り直す。
#   scripts/demo/record.sh [basic parallel states team link]
#
# - 普段の Jellyfish AI を一度終了し、JELLYFISH_DATA_DIR で空のデモ用データから起動して録画する
#   （JELLYFISH_AUTOMATION=1 で、指示の送信などデモ用の jellyfish:// 操作を受け付ける）
#   （普段のクラゲ・会話・設定には触れない。録画後に普段のアプリを起動し直す）
# - basic / parallel は実際に Claude Code へ指示を送る（作業フォルダは ~/jellyfish-demo）
# - 録画範囲は 1920x1080 pt のメインディスプレイ右上を前提にしている（scripts/demo/*.json の region）
# - 録画中はキーボード・マウスに触らない（チャットウィンドウがフォーカスを持つ）
# - 撮影するプロセス（ターミナル / VS Code）に「画面収録」の許可が必要
set -e
cd "$(dirname "$0")/../.."
takes=(${@:-basic parallel states team link})
[[ -d dist/JellyfishAI.app ]] || scripts/build.sh
mkdir -p .build ~/jellyfish-demo
swiftc -O scripts/demo/recorder.swift -o .build/recorder
for name in $takes; do
  pkill -x JellyfishAI || true
  while pgrep -x JellyfishAI >/dev/null; do /bin/sleep 0.1; done
  data="$PWD/.build/demo-data/$name"
  rm -rf "$data" ".build/demo-frames/$name"; mkdir -p "$data"
  cp scripts/demo/seed/$name/*.json "$data/"
  # 前の録画で覚えたチャットウィンドウの位置・大きさを消す（シードのクラゲは毎回同じ ID）
  for id in $(grep -oE '[0-9A-F]{8}-[0-9A-F-]{27}' scripts/demo/seed/$name/jellies.json); do
    defaults delete ai.jellyfish.desktop "NSWindow Frame JellyfishChat-$id" 2>/dev/null || true
  done
  open --env JELLYFISH_DATA_DIR="$data" --env JELLYFISH_AUTOMATION=1 dist/JellyfishAI.app
  .build/recorder "scripts/demo/$name.json" ".build/demo-frames/$name"
  pkill -x JellyfishAI || true
  /bin/sleep 0.5
done
open dist/JellyfishAI.app
"${PYTHON:-python3}" scripts/demo/make_gif.py .build/demo-frames docs/media $takes
