#!/bin/bash
# GitHub Releases のダウンロード数を見る（GitHub が数えている、リリースに付けたファイルごとの download_count）。
#   scripts/downloads.sh            リリースごと・ファイルごとの数と合計
#   scripts/downloads.sh --traffic  あわせて、直近 14 日のリポジトリの閲覧数・clone 数（push できる人だけ見られる）
#   scripts/downloads.sh --json     リリースごとの数を JSON で
# 数え方：
#   .dmg  = README の「ダウンロード」やリリースのページからのダウンロード（新しく入れる人・手で入れ替える人）
#   .zip  = アプリの「アップデートする」と、手での .zip のダウンロード
#   SHA256SUMS.txt はアップデートのたびと、チェックサムを確かめる人が取るので、人数には数えない
# GitHub は同じ人の 2 回目も数え、開発中の確認で取った分も入る。clone・ソースの zip（Source code）は数えない
set -euo pipefail
REPO="${JELLYFISH_REPO:-Rhizobium-gits/jellyfish-ai}"
TRAFFIC=0
JSON=0
for a in "$@"; do
  case "$a" in
    --traffic) TRAFFIC=1 ;;
    --json) JSON=1 ;;
    *) echo "unknown argument: $a" >&2; exit 2 ;;
  esac
done
command -v gh >/dev/null || { echo "gh（GitHub CLI）が要ります: brew install gh" >&2; exit 1; }

# 版・公開日・dmg・zip・SHA256SUMS・ほか
ROWS="$(gh api "repos/$REPO/releases" --paginate --jq '.[] | select(.draft | not) | [
  .tag_name,
  (.published_at // "" | .[0:10]),
  ([.assets[] | select(.name | endswith(".dmg")) | .download_count] | add // 0),
  ([.assets[] | select(.name | endswith(".zip")) | .download_count] | add // 0),
  ([.assets[] | select(.name == "SHA256SUMS.txt") | .download_count] | add // 0),
  ([.assets[] | select((.name | endswith(".dmg") or endswith(".zip")) | not) | select(.name != "SHA256SUMS.txt") | .download_count] | add // 0)
] | @tsv')"

if [[ $JSON == 1 ]]; then
  printf '%s\n' "$ROWS" | awk -F'\t' 'BEGIN { printf "[" } NF {
    printf "%s{\"tag\":\"%s\",\"published\":\"%s\",\"dmg\":%d,\"zip\":%d,\"sha256sums\":%d,\"other\":%d}", (n++ ? "," : ""), $1, $2, $3, $4, $5, $6
  } END { print "]" }'
  exit 0
fi

printf '%s\n' "$ROWS" | awk -F'\t' '
  BEGIN { printf "版        公開日      %8s %8s %8s\n", ".dmg", ".zip", "SUMS" }
  NF { printf "%-9s %-11s %8d %8d %8d\n", $1, $2, $3, $4, $5; d += $3; z += $4; s += $5 }
  END {
    printf "合計                  %8d %8d %8d\n", d, z, s
    print ""
    print ".dmg = ダウンロードして入れた回数（README・リリースのページから）"
    print ".zip = アプリの「アップデートする」と、手での .zip のダウンロード"
  }'

if [[ $TRAFFIC == 1 ]]; then
  echo
  if V="$(gh api "repos/$REPO/traffic/views" --jq '"\(.count)\t\(.uniques)"' 2>/dev/null)" &&
     C="$(gh api "repos/$REPO/traffic/clones" --jq '"\(.count)\t\(.uniques)"' 2>/dev/null)"; then
    printf '直近 14 日：ページの閲覧 %s 回（%s 人）・clone %s 回（%s 人）\n' "${V%%$'\t'*}" "${V##*$'\t'}" "${C%%$'\t'*}" "${C##*$'\t'}"
  else
    echo "閲覧数・clone 数は、このリポジトリに push できるアカウントでだけ見られます（gh auth status で確かめてください）"
  fi
fi
