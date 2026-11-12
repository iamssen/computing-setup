#!/bin/bash
# 지정한 SHA-1 지문의 코드 서명 인증서가 키체인에 유효하게 있는지 확인한다.
#   main.sh <identity>
# fish의 validate-signing-identity 명령과 dagu/main.sh가 호출한다.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../_shared/lib.sh"

(( $# == 1 )) || usage_error 'validate-signing-identity <identity>'
identity=$1
if [[ -z $identity ]]; then
    fail 'Set SIGNING_IDENTITY to the SHA-1 fingerprint of your signing certificate.'
fi

# -v는 만료되지 않았고 개인 키가 있으며 신뢰되는 인증서만 나열한다.
# 각 줄은 '  1) <지문> "<이름>"' 형식이므로 둘째 열이 지문이다.
identities=$(security find-identity -v -p codesigning)
if ! awk -v identity="$identity" \
    '$1 ~ /^[0-9]+\)$/ && $2 == identity {found = 1} END {exit !found}' <<< "$identities"; then
    fail 'The signing certificate is not valid. Check its expiration, private key, and trust settings.'
fi
