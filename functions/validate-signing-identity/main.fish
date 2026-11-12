# 코드 서명 인증서 확인 명령. 실제 작업은 main.sh가 한다.
set -l script (status dirname)/main.sh

function validate-signing-identity --description 'Check that a code signing certificate is valid' \
    --inherit-variable script
    /bin/bash "$script" $argv
end
