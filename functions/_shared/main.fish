# 여러 모듈이 함께 쓰는 비공개 fish 헬퍼.

# stdin의 각 줄에 색을 입혀 출력한다.
#   "[Action] command"            → 실행할 수 있는 명령 안내. 대괄호 부분을 강조한다.
#   "Name - up to date ..."       → 최신 상태. 상태 문구를 강조한다. 유효한 인증서의 "Name - valid ..."도 같다.
#   그 외                          → 그대로 출력한다.
function _computing_setup_format
    set -l action_color ''
    set -l status_color ''
    set -l reset ''
    if isatty stdout; and not set -q NO_COLOR
        set action_color (set_color --bold yellow)
        set status_color (set_color --bold green)
        set reset (set_color --reset)
    end

    while read -l line
        set -l action (string match --regex '^(\[[^]]+\]) (.+)$' -- "$line")
        if test (count $action) -eq 3
            printf '  %s%s%s %s\n' "$action_color" "$action[2]" "$reset" "$action[3]"
            continue
        end

        set -l current (string match --regex '^(.+ - )(up to date|newer than latest|valid)(.*)$' -- "$line")
        if test (count $current) -ge 3
            printf '%s%s%s%s%s\n' "$current[2]" "$status_color" "$current[3]" "$reset" "$current[4]"
        else
            printf '%s\n' "$line"
        end
    end
end

# 점검 명령의 종료 코드가 실패가 아닌지 판단한다.
# 계약: 0 = 최신 상태, 100 = 업데이트 있음, 101 = 미설치. 그 외는 모두 실패다.
# bash 쪽 상수는 _shared/lib.sh의 EXIT_UPDATE_AVAILABLE, EXIT_NOT_INSTALLED다.
function _computing_setup_check_succeeded --argument-names check_status
    contains -- "$check_status" 0 100 101
end
