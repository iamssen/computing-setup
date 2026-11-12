# 모든 모듈의 main.sh가 source하는 공용 함수. 단독으로 실행하지 않는다.
# macOS 기본 /bin/bash(3.2)에서 동작해야 한다.

# check 서브커맨드의 종료 코드 계약. 0은 최신 상태, 아래 두 값 외에는 모두 실패다.
# fish 쪽에서는 _computing_setup_check_succeeded가 같은 계약을 해석한다.
readonly EXIT_UPDATE_AVAILABLE=100
readonly EXIT_NOT_INSTALLED=101

# 메시지를 stderr로 출력하고 실패(1)로 종료한다.
fail() {
    echo "$*" >&2
    exit 1
}

# 사용법을 stderr로 출력하고 인자 오류(2)로 종료한다.
# 사용자는 fish 명령만 보므로 사용법에는 스크립트가 아닌 fish 명령 이름을 쓴다.
usage_error() {
    echo "Usage: $*" >&2
    exit 2
}

# URL($1)을 파일($2)로 내려받는다. 리다이렉트를 포함해 HTTPS만 허용한다.
download() {
    curl -fsSL --retry 2 --connect-timeout 15 --max-time 300 \
        --proto '=https' --proto-redir '=https' "$1" -o "$2"
}

# vX.Y.Z 형식의 두 버전을 자리별로 비교해, $1이 $2보다 높을 때만 성공한다.
version_is_newer() {
    local -a candidate_parts current_parts
    local i
    IFS=. read -r -a candidate_parts <<< "${1#v}"
    IFS=. read -r -a current_parts <<< "${2#v}"
    for i in 0 1 2; do
        # 10#은 08, 09처럼 0으로 시작하는 숫자가 8진수로 해석되는 것을 막는다.
        if (( 10#${candidate_parts[i]} > 10#${current_parts[i]} )); then
            return 0
        elif (( 10#${candidate_parts[i]} < 10#${current_parts[i]} )); then
            return 1
        fi
    done
    return 1
}
