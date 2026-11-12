# Dagu 설치·업데이트 명령. 실제 작업은 main.sh가 한다.
set -l script (status dirname)/main.sh

function check-dagu-update --description 'Check Dagu releases' --inherit-variable script
    # 출력에는 색을 입히고, 종료 코드는 스크립트의 것을 그대로 돌려준다.
    /bin/bash "$script" check $argv | _computing_setup_format
    return $pipestatus[1]
end

function setup-dagu --description 'Install, sign, and start Dagu' --inherit-variable script
    # SIGNING_IDENTITY가 export되지 않은 변수여도 스크립트가 읽을 수 있게, 이 함수 안에서만 export한다.
    set -lx SIGNING_IDENTITY "$SIGNING_IDENTITY"
    /bin/bash "$script" setup $argv
end

function update-dagu --description 'Update, verify, and restart Dagu' --inherit-variable script
    set -lx SIGNING_IDENTITY "$SIGNING_IDENTITY"
    /bin/bash "$script" update $argv
end
