#!/bin/bash
# Jellyfish AI 専用の署名用の証明書（自己署名）を、この Mac のログインキーチェーンに作る・確かめる・消す。
#   scripts/signing.sh status   あるかどうか
#   scripts/signing.sh create   作る（有効期限 10 年）
#   scripts/signing.sh delete   消す（証明書と秘密鍵）
#
# なぜ要るか：アドホック署名だと、macOS はビルドし直すたび・新しい版に入れ替えるたびに「別のアプリ」とみなし、
#   フォルダ（デスクトップ・書類など）・アクセシビリティ・画面収録の許可をもう一度求める。
#   同じ証明書で署名すると「ai.jellyfish.desktop をこの証明書で署名したもの」として同じアプリと扱われ、一度の許可が続く。
# 安全のための決まり：
#   - 秘密鍵はキーチェーンから取り出せない設定で入れる（-x）。作業用の一時ファイルはすぐ消す
#   - codesign にも事前に許可しない。署名するたびに macOS が「codesign がキーを使おうとしています」と確認する
#     （ほかのプログラムが黙ってこの証明書で署名し、Jellyfish に付いた許可を引き継ぐことができないように）
#   - 信頼の設定（システムの証明書の信頼）は変えない。Gatekeeper の扱いはアドホック署名と同じ（初回は「このまま開く」）
# scripts/build.sh --sign（scripts/install.sh・scripts/release.sh はあれば自動で）がこの証明書で署名する。
set -euo pipefail
NAME="${JELLYFISH_SIGN_IDENTITY:-Jellyfish AI Local Signing}"
KC="$HOME/Library/Keychains/login.keychain-db"

exists() { local ids; ids="$(security find-identity -p codesigning "$KC" 2>/dev/null || true)"; [[ "$ids" == *"\"${NAME}\""* ]]; }

case "${1:-status}" in
  status)
    if exists; then
      echo "ある: ${NAME}"
      security find-identity -p codesigning "$KC" | grep "\"${NAME}\"" | sed 's/^ *[0-9]*) //'
      echo "（CSSMERR_TP_NOT_TRUSTED と出るのは自己署名のため。署名には使える）"
    else
      echo "ない: ${NAME}（scripts/signing.sh create で作る）"
      exit 1
    fi
    ;;
  create)
    if exists; then echo "もうあります: ${NAME}"; exit 0; fi
    umask 077
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = ${NAME}
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    # macOS の security が読める PKCS#12 にするため、システムの /usr/bin/openssl（LibreSSL）を使う
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
    PASS="$(/usr/bin/openssl rand -hex 24)"
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS" -name "${NAME}"
    # -x：秘密鍵を取り出せないようにする。-T を付けない：どのアプリにも事前に使う許可を与えない
    security import "$TMP/id.p12" -k "$KC" -P "$PASS" -x >/dev/null
    echo "作りました: ${NAME}"
    security find-identity -p codesigning "$KC" | grep "\"${NAME}\"" | sed 's/^ *[0-9]*) //'
    echo "署名のたびに macOS が確認します。「許可」を押してください（「常に許可」にすると、codesign を使うほかのプログラムも確認なしでこの証明書を使えるようになります）。"
    ;;
  delete)
    if ! exists; then echo "ありません: ${NAME}"; exit 0; fi
    security delete-identity -c "${NAME}" "$KC"
    echo "消しました: ${NAME}（次のビルドからアドホック署名に戻ります。macOS の許可はもう一度求められます）"
    ;;
  *)
    echo "usage: scripts/signing.sh status|create|delete" >&2
    exit 2
    ;;
esac
