#!/bin/bash
# テストを実行する（swift test）。
# Command Line Tools だけの環境では Swift Testing の置き場所を swift test が見つけないので、場所を教える。
set -euo pipefail
cd "$(dirname "$0")/.."
# テスト中のログやデータは使い捨てのフォルダへ（普段の ~/Library/Application Support/JellyfishAI に書かない）
export JELLYFISH_DATA_DIR="$(mktemp -d)/data"
# 表示の言語は日本語に固定（文字を確かめるテストがあるため。CI の macOS は英語）
export JELLYFISH_LANGUAGE=ja
DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV" == *CommandLineTools* ]]; then
  D="$DEV/Library/Developer"
  exec swift test \
    -Xswiftc -F -Xswiftc "$D/Frameworks" \
    -Xlinker -F -Xlinker "$D/Frameworks" \
    -Xlinker -rpath -Xlinker "$D/Frameworks" \
    -Xlinker -rpath -Xlinker "$D/usr/lib" "$@"
fi
exec swift test "$@"
