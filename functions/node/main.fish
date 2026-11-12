# Node.js 공식 pkg 관리 명령. 실제 작업은 main.sh가 한다.
set -l script (status dirname)/main.sh
set -l after_install (status dirname)/after-install.fish

function check-node-update --description 'Check official Node.js releases' --inherit-variable script
    # 출력에는 색을 입히고, 종료 코드는 스크립트의 것을 그대로 돌려준다.
    /bin/bash "$script" check $argv | _computing_setup_format
    return $pipestatus[1]
end

function install-node --description 'Install an official Node.js release directory' \
    --inherit-variable script --inherit-variable after_install
    set -l version_before (/bin/bash "$script" current)
    or return $status

    /bin/bash "$script" install $argv
    or return $status

    set -l version_after (/bin/bash "$script" current)
    or return $status

    # 기존 설치의 버전이 실제로 바뀐 경우에만 후처리를 실행한다.
    if test -n "$version_before"; and test "$version_before" != "$version_after"
        source "$after_install"
        or return $status
    end
    return 0
end
