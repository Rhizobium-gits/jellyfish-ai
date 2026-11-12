#!/bin/bash
# Jellyfish AI の macOS の許可（プライバシーとセキュリティ）を、コマンドでまとめて扱う。
# 使うのは macOS の公式の道具だけ（tccutil・システム設定）。許可そのものは、システム設定で本人がオンにする
# （macOS は、アプリやコマンドが許可を勝手に付けることを許さない。Jellyfish もしない）。
#   permissions.sh status                今の状態をアプリの「🔐 権限」の画面で見る（署名の種類はここにも出す）
#   permissions.sh grant [サービス…]     前の版に付いていた古い許可を消して（tccutil reset）、アプリに許可を求めさせる
#                                        サービスを省くと、下の一覧すべて
#   permissions.sh revoke                Jellyfish AI の許可をすべて取り消す（tccutil reset All ai.jellyfish.desktop）
# サービス：Accessibility（PC 操作のクリック・入力） ScreenCapture（画面の撮影・🎧 システムの音）
#           SystemPolicyAllFiles（フルディスクアクセス） SystemPolicyDesktopFolder SystemPolicyDocumentsFolder
#           SystemPolicyDownloadsFolder（デスクトップ・書類・ダウンロード） AppleEvents（ほかのアプリの操作）
# アプリの中にも同じものが入っている：/Applications/JellyfishAI.app/Contents/Resources/permissions.sh
# なぜ「古い許可を消す」のか：アドホック署名の版は、更新のたびに macOS から別のアプリに見える。
#   システム設定のスイッチはオンのままでも前の版に付いた許可なので効かず、何度も許可を求められる。
#   消してから許可し直すと、いまの版に付く（scripts/signing.sh で固定の署名にすると、次からの更新でも続く）
set -euo pipefail
# アプリの中から動かしたときは、そのアプリのバンドル ID（ほかのコピーの許可には触らない）
SELF_APP="$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd || true)"
BID="${JELLYFISH_BUNDLE_ID:-}"
if [[ -z "$BID" && "$SELF_APP" == *.app && -f "$SELF_APP/Contents/Info.plist" ]]; then
  BID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$SELF_APP/Contents/Info.plist" 2>/dev/null || true)"
fi
BID="${BID:-ai.jellyfish.desktop}"
[[ "$BID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "バンドル ID を読めません: $BID" >&2; exit 2; }
TCCUTIL="${JELLYFISH_TCCUTIL:-/usr/bin/tccutil}"   # テストで差し替える
OPEN="${JELLYFISH_OPEN:-/usr/bin/open}"
ALL_SERVICES=(Accessibility ScreenCapture SystemPolicyAllFiles SystemPolicyDesktopFolder SystemPolicyDocumentsFolder SystemPolicyDownloadsFolder AppleEvents)

known() { local s; for s in "${ALL_SERVICES[@]}"; do [[ "$s" == "$1" ]] && return 0; done; return 1; }
run() { printf '  $ %s\n' "$*"; "$@"; }

cmd="${1:-status}"
shift || true
case "$cmd" in
  status)
    if [[ "$SELF_APP" == *.app ]]; then APP="$SELF_APP"; else
      APP=/Applications/JellyfishAI.app
      [[ -d "$APP" || ! -d "$HOME/Applications/JellyfishAI.app" ]] || APP="$HOME/Applications/JellyfishAI.app"
    fi
    if [[ -d "$APP" ]]; then
      SIG="$(codesign -d --verbose=2 "$APP" 2>&1 || true)"
      if [[ "$SIG" == *$'\nAuthority='* ]]; then
        echo "署名: 証明書（$(printf '%s\n' "$SIG" | sed -n 's/^Authority=//p' | head -1)）。更新しても許可は続きます"
      else
        echo "署名: 仮の署名（ad-hoc）。更新のたびに、許可をし直すことがあります（固定の署名にするには scripts/signing.sh create → scripts/install.sh）"
      fi
    fi
    echo "許可の状態は、アプリの「🔐 権限」の画面に出します"
    "$OPEN" -g "jellyfish://permissions"
    ;;
  grant)
    SERVICES=("$@")
    [[ ${#SERVICES[@]} -gt 0 ]] || SERVICES=("${ALL_SERVICES[@]}")
    for s in "${SERVICES[@]}"; do known "$s" || { echo "知らないサービスです: $s" >&2; exit 2; }; done
    echo "🪼 Jellyfish AI（${BID}）の、前の版に付いていた古い許可を消します（ほかのアプリの許可には触りません）:"
    for s in "${SERVICES[@]}"; do
      run "$TCCUTIL" reset "$s" "$BID" || echo "  （$s は消せませんでした。システム設定で一度オフにしてからオンにしてください）"
    done
    echo
    echo "続けて、Jellyfish AI が許可を求めます。出てきた macOS の確認と、システム設定の画面で Jellyfish AI をオンにしてください。"
    echo "（画面収録は、オンにしたあと「終了して再度開く」を選ぶと効きます）"
    "$OPEN" -g "jellyfish://permissions?done=grant"
    ;;
  revoke)
    echo "🪼 Jellyfish AI（${BID}）の許可をすべて取り消します（ほかのアプリの許可には触りません）:"
    run "$TCCUTIL" reset All "$BID"
    echo
    echo "取り消しました。PC 操作・画面の添付・🎧 は、もう一度許可するまで使えません。"
    echo "確かめるなら：システム設定 › プライバシーとセキュリティ（アクセシビリティ・画面収録・フルディスクアクセス・オートメーション）"
    "$OPEN" -g "jellyfish://permissions?done=revoke"
    ;;
  -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command: ${cmd}（status / grant / revoke）" >&2; exit 2 ;;
esac
