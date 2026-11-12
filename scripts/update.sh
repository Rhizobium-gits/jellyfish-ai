#!/bin/bash
# Jellyfish AI を新しい版に上げる（コマンド 1 つで）。
#   scripts/update.sh             GitHub の最新リリースが新しければ、確かめてから入れ替えて開き直す
#   scripts/update.sh --check     新しい版があるかだけ見る（終了コード 0 = 最新、10 = 新しい版がある）
#   scripts/update.sh --source    ソースから上げる（git pull --ff-only → scripts/install.sh。署名用の証明書があればそれで署名）
#   scripts/update.sh --yes       「入れ替えますか？」を聞かない
#   scripts/update.sh --app PATH  入れ替える .app（既定は /Applications/JellyfishAI.app、無ければ ~/Applications/JellyfishAI.app）
#   scripts/update.sh --no-open   入れ替えたあと開かない
# アプリの中にも同じものが入っている（ソースが無くても使える）：
#   /Applications/JellyfishAI.app/Contents/Resources/update.sh
# リリース版に入れ替える前に確かめること（アプリの「アップデートする」と同じ）：
#   ・取ってくるのは https://github.com/<repo>/releases/download/<tag>/ の JellyfishAI-<版>.zip と SHA256SUMS.txt だけ
#   ・SHA-256 が合うか、中身のバンドル ID と版、codesign --verify --strict、
#     いまの版が証明書で署名されていれば、新しい版も同じ証明書の署名か（違えば入れ替えない）
#   ・作業中のクラゲ（アプリの子プロセス）がいるときは入れ替えない。sudo は使わない
set -euo pipefail

REPO="${JELLYFISH_REPO:-Rhizobium-gits/jellyfish-ai}"
BUNDLE_ID=ai.jellyfish.desktop
CHECK=0 SOURCE=0 YES=0 OPEN=1 APP=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1 ;;
    --source) SOURCE=1 ;;
    --yes|-y) YES=1 ;;
    --no-open) OPEN=0 ;;
    --app) shift; APP="${1:-}"; [[ -n "$APP" ]] || { echo "--app には .app の場所を付けてください" >&2; exit 2; } ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

# アプリの中から動かしたときは、入れ替えで自分が消えないよう、写しから動かし直す
if [[ "$0" == *.app/Contents/* && -z "${JELLYFISH_UPDATE_COPY:-}" ]]; then
  COPY="$(mktemp -t jellyfish-update).sh"
  cp "$0" "$COPY"
  chmod 700 "$COPY"
  ARGS=()
  [[ $CHECK == 1 ]] && ARGS+=(--check)
  [[ $SOURCE == 1 ]] && ARGS+=(--source)
  [[ $YES == 1 ]] && ARGS+=(--yes)
  [[ $OPEN == 0 ]] && ARGS+=(--no-open)
  [[ -n "$APP" ]] && ARGS+=(--app "$APP")
  JELLYFISH_UPDATE_COPY=1 exec /bin/bash "$COPY" ${ARGS[@]+"${ARGS[@]}"}
fi

say() { printf '%s\n' "$*"; }
fail() { printf '⚠️ %s\n' "$*" >&2; exit 1; }

# 版を比べる：$1 が $2 より新しければ 0（先頭の v と、- から後ろは見ない）
newer() {
  local a="${1#v}" b="${2#v}"
  a="${a%%-*}"; b="${b%%-*}"
  local IFS=.
  local -a x=($a) y=($b)
  local i
  for i in 0 1 2 3; do
    local p="${x[$i]:-0}" q="${y[$i]:-0}"
    [[ "$p" =~ ^[0-9]+$ ]] || p=0
    [[ "$q" =~ ^[0-9]+$ ]] || q=0
    (( 10#$p > 10#$q )) && return 0
    (( 10#$p < 10#$q )) && return 1
  done
  return 1
}

plist_value() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null || true; }

confirm() {
  [[ $YES == 1 ]] && return 0
  [[ -t 0 ]] || fail "確かめの質問に答えられません（ターミナルの外から動かすときは --yes を付けてください）"
  local r
  read -r -p "$1 [y/N] " r
  [[ "$r" == y || "$r" == Y || "$r" == yes ]]
}

# 入れ替える .app
if [[ -z "$APP" ]]; then
  APP=/Applications/JellyfishAI.app
  [[ -d "$APP" || ! -d "$HOME/Applications/JellyfishAI.app" ]] || APP="$HOME/Applications/JellyfishAI.app"
fi
APP="${APP%/}"

# APP で動いている Jellyfish AI のプロセス（同じ名前のほかのコピーは数えない）
app_pids() {
  local p
  for p in $(pgrep -x JellyfishAI || true); do
    [[ "$(ps -o comm= -p "$p" 2>/dev/null || true)" == "$APP/Contents/MacOS/JellyfishAI" ]] && echo "$p"
  done
  return 0
}
app_busy() {
  local p
  for p in $(app_pids); do pgrep -P "$p" >/dev/null && return 0; done
  return 1
}

# ---------- ソースから ----------
if [[ $SOURCE == 1 ]]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  [[ -d "$ROOT/.git" && -x "$ROOT/scripts/install.sh" ]] || fail "--source はソースのフォルダ（git clone したもの）の scripts/update.sh から動かしてください"
  cd "$ROOT"
  [[ -z "$(git status --porcelain)" ]] || fail "まだコミットしていない変更があるので、取り込みません（git status で確かめてください）"
  git fetch --quiet
  UP="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || fail "このブランチには取り込み元（upstream）がありません"
  BEHIND="$(git rev-list --count "HEAD..$UP")"
  INSTALLED="$(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString)"
  REMOTE_VERSION="$(git show "$UP:VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "$BEHIND" == 0 ]]; then
    say "ソースは最新です（${UP}）。入っているのは ${INSTALLED:-（未インストール）}"
    [[ $CHECK == 1 ]] && exit 0
    confirm "このソースでビルドし直して入れ替えますか？" || { say "やめました"; exit 0; }
  else
    say "新しいコミットが $BEHIND 件あります（$UP の版: ${REMOTE_VERSION:-?}、入っているのは ${INSTALLED:-（未インストール）}）"
    git log --oneline "HEAD..$UP" | head -10
    [[ $CHECK == 1 ]] && exit 10
    confirm "取り込んで（git pull --ff-only）、ビルドして入れ替えますか？" || { say "やめました"; exit 0; }
    git pull --ff-only --quiet
  fi
  exec scripts/install.sh
fi

# ---------- リリース版 ----------
INSTALLED="$(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString)"
if [[ -d "$APP" && "$(plist_value "$APP/Contents/Info.plist" CFBundleIdentifier)" != "$BUNDLE_ID" ]]; then
  fail "$APP は Jellyfish AI ではありません"
fi

WORK="$(mktemp -d -t jellyfish-update)"
trap 'rm -rf "$WORK"' EXIT
J="$WORK/latest.json"
if [[ -n "${JELLYFISH_RELEASE_JSON:-}" ]]; then
  cp "$JELLYFISH_RELEASE_JSON" "$J"   # テスト用
else
  curl -fsSL --proto '=https' --tlsv1.2 -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/releases/latest" -o "$J" || fail "GitHub から最新のリリースを読めませんでした"
fi
TAG="$(plist_value "$J" tag_name)"
[[ "$TAG" =~ ^v?[0-9]+(\.[0-9]+){1,3}$ ]] || fail "リリースの番号を読めません（${TAG:-なし}）"
VERSION="${TAG#v}"

if [[ -n "$INSTALLED" ]] && ! newer "$VERSION" "$INSTALLED"; then
  say "最新です（入っているのは ${INSTALLED}、最新のリリースは ${VERSION}）"
  exit 0
fi

# このリポジトリのこのリリースのファイルだけを使う
ZIP_NAME="JellyfishAI-$VERSION.zip"
PREFIX="https://github.com/$REPO/releases/download/$TAG/"
ZIP_URL="" SUMS_URL=""
N="$(plist_value "$J" assets)"
[[ "$N" =~ ^[0-9]+$ ]] || N=0
for (( i = 0; i < N; i++ )); do
  name="$(plist_value "$J" "assets.$i.name")"
  url="$(plist_value "$J" "assets.$i.browser_download_url")"
  case "$name" in
    "$ZIP_NAME") [[ "$url" == "$PREFIX$ZIP_NAME" ]] && ZIP_URL="$url" ;;
    SHA256SUMS.txt) [[ "$url" == "${PREFIX}SHA256SUMS.txt" ]] && SUMS_URL="$url" ;;
  esac
done
[[ -n "$ZIP_URL" && -n "$SUMS_URL" ]] || fail "リリース $TAG に $ZIP_NAME と SHA256SUMS.txt が見つかりません（https://github.com/$REPO/releases から入れ直してください）"

say "新しい版 $VERSION があります（入っているのは ${INSTALLED:-（未インストール）}）"
say "  $ZIP_URL"
[[ $CHECK == 1 ]] && exit 10
confirm "ダウンロードして、確かめてから入れ替えますか？" || { say "やめました"; exit 0; }

say "ダウンロードしています…"
curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 "$SUMS_URL" -o "$WORK/SHA256SUMS.txt" || fail "SHA256SUMS.txt をダウンロードできませんでした"
curl -fL --proto '=https' --proto-redir '=https' --tlsv1.2 --progress-bar "$ZIP_URL" -o "$WORK/$ZIP_NAME" || fail "$ZIP_NAME をダウンロードできませんでした"

say "確かめています…"
EXPECTED="$(awk -v f="$ZIP_NAME" '$2 == f || $2 == "*" f { print tolower($1) }' "$WORK/SHA256SUMS.txt" | head -1)"
[[ "$EXPECTED" =~ ^[0-9a-f]{64}$ ]] || fail "SHA256SUMS.txt に $ZIP_NAME がありません"
ACTUAL="$(shasum -a 256 "$WORK/$ZIP_NAME" | awk '{ print $1 }')"
[[ "$ACTUAL" == "$EXPECTED" ]] || fail "チェックサムが合いません（ダウンロードが壊れているか、書き換えられています）"
/usr/bin/ditto -x -k "$WORK/$ZIP_NAME" "$WORK/new" || fail "ダウンロードしたファイルを開けません"
NEW="$WORK/new/JellyfishAI.app"
[[ -d "$NEW" && ! -L "$NEW" ]] || fail "中身が Jellyfish AI ではありません"
[[ "$(plist_value "$NEW/Contents/Info.plist" CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "中身が Jellyfish AI ではありません"
[[ "$(plist_value "$NEW/Contents/Info.plist" CFBundleShortVersionString)" == "$VERSION" ]] || fail "中身の版がリリースと合いません"
codesign --verify --strict "$NEW" 2>/dev/null || fail "署名が正しくありません"
if [[ -d "$APP" ]]; then
  SIG="$(codesign -d --verbose=2 "$APP" 2>&1 || true)"
  if [[ "$SIG" == *$'\nAuthority='* ]]; then
    # いまの版が証明書で署名されていれば、同じ証明書の署名であること
    DR="$(codesign -d -r- "$APP" 2>&1 | sed -n 's/^designated => //p')"
    [[ -n "$DR" ]] && { codesign --verify -R="$DR" "$NEW" 2>/dev/null || fail "いまの版と署名が違います（自分でビルドした版なら scripts/update.sh --source で上げてください）"; }
  fi
fi

# 動いていれば終える（作業中なら何もしない）
WAS_RUNNING=0
if [[ -n "$(app_pids)" ]]; then
  WAS_RUNNING=1
  app_busy && fail "作業中のクラゲがいるので、入れ替えをやめました。終わってからもう一度実行してください"
  for p in $(app_pids); do kill -TERM "$p" 2>/dev/null || true; done
  for _ in $(seq 100); do [[ -z "$(app_pids)" ]] && break; /bin/sleep 0.1; done
  [[ -z "$(app_pids)" ]] || fail "Jellyfish AI が終わらないので、入れ替えをやめました。メニューバーのクラゲから終了してから、もう一度実行してください"
fi

say "入れ替えています…"
mkdir -p "$(dirname "$APP")"
if [[ -d "$APP" ]]; then
  BAK="$WORK/previous.app"
  mv "$APP" "$BAK" 2>/dev/null || fail "いまの版を動かせません（macOS が止めた場合は、システム設定 › プライバシーとセキュリティ › アプリ管理 で、このターミナルを許可してください）"
  if ! mv "$NEW" "$APP"; then
    mv "$BAK" "$APP" || fail "新しい版を置けず、元にも戻せませんでした。いまの版は $BAK にあります"
    trap - EXIT
    fail "新しい版を置けませんでした。いまの版はそのままです"
  fi
else
  mv "$NEW" "$APP" || fail "新しい版を置けませんでした"
fi
say "✅ Jellyfish AI $VERSION にしました（${APP}）"
[[ "$(codesign -d --verbose=2 "$APP" 2>&1 || true)" == *$'\nAuthority='* ]] || \
  say "  ・仮の署名（ad-hoc）の版なので、PC 操作・画面の添付を使うなら、システム設定 › プライバシーとセキュリティ で許可し直すことがあります"
if [[ $OPEN == 1 ]]; then open -g "$APP"; fi
exit 0
