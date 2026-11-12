#!/bin/bash
# CodexBar의 External event hook으로 등록해서, 이벤트를 `pushover system "<메시지>"`로 아이폰에 보낸다.
# CodexBar 설정 > Hooks에서 executable을 이 파일의 절대 경로로, arguments는 비워 둔다.
# 이벤트 내용은 CodexBar가 넘기는 CODEXBAR_* 환경 변수에서 읽는다. stdin의 JSON은 같은 내용이라 읽지 않는다.
set -euo pipefail

# CodexBar는 PATH를 거의 넘기지 않으므로 fish를 절대 경로로 찾는다. 변수는 테스트 전용이다.
FISH_BIN=${COMPUTING_SETUP_FISH:-/opt/homebrew/bin/fish}
LOADER="$(cd "$(dirname "$0")" && pwd)/functions.fish"

# 제공자 이름의 첫 글자를 대문자로 바꾼다(claude → Claude).
provider_label() {
  local name=$1
  printf '%s%s' "$(printf '%s' "${name:0:1}" | tr '[:lower:]' '[:upper:]')" "${name:1}"
}

# 0...1 비율을 정수 퍼센트 문자열로 바꾼다(0.42 → 42%).
percent_label() {
  awk -v value="$1" 'BEGIN { printf "%.0f%%", value * 100 }'
}

# UTC ISO 8601 시각을 로컬 시각(MM-DD HH:MM)으로 바꾼다. 소수 초가 붙어 있으면 버린다.
local_time_label() {
  local iso=${1%%.*}
  iso=${iso%Z}
  local epoch
  epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$iso" +%s 2>/dev/null) || return 1
  date -r "$epoch" '+%m-%d %H:%M'
}

# 이벤트 종류에 따라 한 줄 메시지를 만든다.
build_message() {
  local event=${CODEXBAR_EVENT:-unknown}
  local provider
  provider=$(provider_label "${CODEXBAR_PROVIDER:-unknown}")

  # 창 이름(session, weekly 등)과 계정은 있을 때만 덧붙인다.
  local subject=$provider
  if [ -n "${CODEXBAR_WINDOW:-}" ]; then
    subject="$subject ${CODEXBAR_WINDOW}"
  fi

  local usage=''
  if [ -n "${CODEXBAR_USAGE_PERCENT:-}" ]; then
    usage=$(percent_label "$CODEXBAR_USAGE_PERCENT")
  fi

  local reset=''
  if [ -n "${CODEXBAR_RESET_AT:-}" ]; then
    reset=$(local_time_label "$CODEXBAR_RESET_AT") || reset=$CODEXBAR_RESET_AT
  fi

  local message
  case "$event" in
    quota_low) message="$subject quota at ${usage:-?}" ;;
    quota_reached) message="$subject quota reached" ;;
    quota_reset) message="$subject quota reset" ;;
    usage_updated) message="$subject usage ${usage:-?}" ;;
    provider_unavailable) message="$provider outage: ${CODEXBAR_STATUS:-unknown}" ;;
    provider_recovered) message="$provider recovered" ;;
    refresh_failed) message="$provider refresh failed: ${CODEXBAR_STATUS:-error}" ;;
    *) message="$provider event: $event" ;;
  esac

  # 리셋 시각은 아직 오지 않은 리셋을 기다리는 이벤트에만 붙인다.
  case "$event" in
    quota_low | quota_reached | usage_updated)
      if [ -n "$reset" ]; then
        message="$message (resets $reset)"
      fi
      ;;
  esac

  if [ -n "${CODEXBAR_ACCOUNT:-}" ]; then
    message="$message [${CODEXBAR_ACCOUNT}]"
  fi
  printf '%s' "$message"
}

main() {
  local message
  message=$(build_message) || return

  # pushover는 fish 함수라서 fish로 부른다. conf.d 링크 여부와 상관없이 동작하도록 로더를 직접 읽는다.
  # 메시지는 인자로 넘겨 fish 코드에 끼워 넣지 않는다.
  exec "$FISH_BIN" -c 'source $argv[1]; and pushover system $argv[2]' "$LOADER" "$message"
}

main "$@"
