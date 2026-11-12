# Pushover로 아이폰에 알림을 보내는 pushover 명령.
#   pushover <channel> "message"
# 채널별 앱 토큰은 PUSHOVER_CHANNEL_<대문자 채널>, 수신자는 PUSHOVER_USER에서 읽는다.
function pushover --description 'Send a message using PUSHOVER_CHANNEL_<ID>'
    # 1. 인자를 검증한다.
    if test (count $argv) -eq 1; and contains -- "$argv[1]" -h --help
        printf '%s\n' 'Usage: pushover <channel> "message"' \
            'Uses PUSHOVER_USER and PUSHOVER_CHANNEL_<UPPERCASE_CHANNEL>.'
        return 0
    end
    if test (count $argv) -ne 2
        echo 'Usage: pushover <channel> "message"' >&2
        return 2
    end
    if not string match --quiet --regex '\A[a-z][a-z0-9_]*\z' -- "$argv[1]"
        echo 'pushover: channel must start with a lowercase letter' \
            'and contain only lowercase letters, digits, or underscores.' >&2
        return 2
    end
    if test -z "$argv[2]"; or test (string length -- "$argv[2]") -gt 1024
        echo 'pushover: message must contain 1 to 1024 characters.' >&2
        return 2
    end

    # 2. 채널 이름으로 토큰 변수를 찾고, 필요한 설정과 도구가 있는지 확인한다.
    set -l token_key PUSHOVER_CHANNEL_(string upper -- "$argv[1]")
    for key in PUSHOVER_USER $token_key
        if not set -q $key; or test -z "$$key"
            printf 'pushover: set %s before sending a message.\n' "$key" >&2
            return 2
        end
    end
    for dependency in curl jq
        if not command -sq $dependency
            printf 'pushover: %s is required.\n' "$dependency" >&2
            return 1
        end
    end

    # 3. 메시지를 보낸다. Dagu의 로컬 명령 제한 시간(30초) 안에 끝나도록 시간을 제한한다.
    # 여기서는 재시도하지 않는다. 재시도는 호출하는 쪽이 맡고, 이미 접수된 메시지를 다시 보내면 중복된다.
    set -l response (command curl --silent --show-error --fail-with-body \
        --connect-timeout 5 --max-time 20 \
        --data-urlencode "token=$$token_key" \
        --data-urlencode "user=$PUSHOVER_USER" \
        --data-urlencode "message=$argv[2]" \
        https://api.pushover.net/1/messages.json)
    set -l request_status $status

    # 4. 전송과 API 응답이 모두 성공이어야 성공이다.
    if test $request_status -eq 0
        if printf '%s\n' $response | command jq -e '.status == 1' >/dev/null 2>&1
            return 0
        end
    end

    # 5. 실패했다면 API가 알려준 오류를 보여주고, curl의 종료 코드가 있으면 그대로 돌려준다.
    set -l errors (printf '%s\n' $response | command jq -r '.errors[]? | select(type == "string")' 2>/dev/null)
    if test (count $errors) -gt 0
        printf 'pushover: %s\n' $errors >&2
    else
        echo 'pushover: message delivery failed or the API returned an invalid response.' >&2
    end
    if test $request_status -ne 0
        return $request_status
    end
    return 1
end
