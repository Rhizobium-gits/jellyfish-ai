#!/bin/bash
# テストを実行する（swift test）。
# Command Line Tools だけの環境では Swift Testing の置き場所を swift test が見つけないので、場所を教える。
set -euo pipefail
cd "$(dirname "$0")/.."
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
