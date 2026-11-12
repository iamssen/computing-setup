#!/bin/bash
# Dagu의 버전 확인, 최초 설치, 업데이트. main.fish의 명령들이 서브커맨드로 호출한다.
#   main.sh check                  업데이트 가능 여부를 출력한다
#   main.sh setup <host> <port>    최초 설치: 바이너리 설치 + LaunchAgent 등록
#   main.sh update                 업데이트: 바이너리 교체 + 서비스 재시작
#
# GitHub 릴리스 바이너리를 SIGNING_IDENTITY 인증서로 다시 서명해서 설치한다.
# 서명이 같아야 업데이트 후에도 macOS 보안 권한이 유지되기 때문이다.
# 설치 도중 실패하면 cleanup이 이전 바이너리와 서비스 상태로 되돌린다.
set -euo pipefail
script_dir=$(dirname "${BASH_SOURCE[0]}")
source "$script_dir/../_shared/lib.sh"

# ── 설정 ─────────────────────────────────────────────────────────────

# 설치 경로. 환경 변수는 테스트에서 경로를 바꾸는 용도로만 쓴다.
dagu=${COMPUTING_SETUP_DAGU_BIN:-/usr/local/bin/dagu}
identifier=local.dagu
release=https://github.com/dagucloud/dagu/releases
release_api=https://api.github.com/repos/dagucloud/dagu/releases/latest
label=local.dagu.server
plist=$HOME/Library/LaunchAgents/$label.plist
log_dir=$HOME/Library/Logs/Dagu
service_domain=gui/$(id -u)
service_target=$service_domain/$label

# ── 실행 상태 ────────────────────────────────────────────────────────

mode=      # check | setup | update
host=      # setup에서만 쓴다
port=
current=   # 설치된 버전(vX.Y.Z). 미설치면 빈 문자열
latest=    # 최신 안정 릴리스 버전
dir=       # 임시 작업 디렉토리

# cleanup이 무엇을 되돌려야 하는지 판단하는 데 쓰는 진행 기록.
stage=                     # 설치 디렉토리에 올려 둔 새 바이너리의 임시 경로
backup=                    # 이전 바이너리의 백업 경로
use_sudo=false             # 설치 디렉토리에 쓰기 권한이 없어 sudo를 쓰는지
binary_replaced=false      # 바이너리를 새 버전으로 교체했는지
plist_created=false        # 이번 실행에서 LaunchAgent plist를 만들었는지
service_was_loaded=false   # 시작 시점에 서비스가 등록되어 있었는지
service_touched=false      # 이번 실행에서 서비스를 내리거나 올렸는지
committed=false            # 모든 단계가 끝나 되돌릴 필요가 없는지

# ── 종료 처리 ────────────────────────────────────────────────────────

# 설치 디렉토리에 쓰는 명령을 필요할 때만 sudo로 실행한다.
install_command() {
    if [[ $use_sudo == true ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

# LaunchAgent를 등록한다. bootout 직후에는 등록이 오류 5로 실패할 수 있어 최대 5회 시도한다.
bootstrap_launchagent() {
    local i result
    for i in {1..5}; do
        if launchctl bootstrap "$service_domain" "$plist" 2> "$dir/bootstrap.error"; then
            return 0
        else
            result=$?
        fi
        if (( result != 5 || i == 5 )); then
            cat "$dir/bootstrap.error" >&2
            return "$result"
        fi
        sleep 1
    done
}

# 스크립트가 어떤 경로로 끝나든 실행된다.
# 완료(committed)되지 않았다면 진행 기록을 보고 시작 전 상태로 되돌린 뒤 임시 파일을 지운다.
cleanup() {
    local result=$? restore_failed=false
    trap - EXIT
    set +e
    if [[ $committed != true ]]; then
        # 1. 새 바이너리로 뜬 서비스를 내린다.
        if [[ $service_touched == true ]]; then
            launchctl bootout "$service_target" >/dev/null 2>&1
        fi
        # 2. 바이너리를 이전 버전으로 되돌린다. 최초 설치였다면 지운다.
        if [[ $binary_replaced == true ]]; then
            if [[ -n $backup ]]; then
                if install_command mv -f "$backup" "$dagu"; then
                    backup=
                    echo 'Restored the previous Dagu binary.' >&2
                else
                    restore_failed=true
                    echo "Failed to restore the previous binary. Backup: $backup" >&2
                fi
            else
                install_command rm -f "$dagu"
            fi
        fi
        # 3. 원래 떠 있던 서비스였다면 이전 바이너리로 다시 띄운다.
        if [[ $service_touched == true && $service_was_loaded == true && $restore_failed != true ]]; then
            bootstrap_launchagent || echo 'Failed to restart the previous Dagu service.' >&2
        fi
        # 4. 이번 실행에서 만든 plist를 지운다.
        if [[ $plist_created == true ]]; then
            rm -f "$plist"
        fi
    fi
    if [[ -n $stage ]]; then
        install_command rm -f "$stage"
    fi
    # 복원에 실패했다면 백업이 유일한 사본이므로 남겨 둔다.
    if [[ -n $backup && $restore_failed != true ]]; then
        install_command rm -f "$backup"
    fi
    rm -rf "$dir"
    exit "$result"
}

# 임시 작업 디렉토리를 만들고 cleanup을 예약한다. 시스템을 변경하기 전에 호출한다.
create_workdir() {
    dir=$(mktemp -d)
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# ── 사전 조건 ────────────────────────────────────────────────────────

is_installed() {
    [[ -e $dagu || -L $dagu ]]
}

require_executable() {
    if [[ ! -x $dagu ]]; then
        fail "Dagu is not executable: $dagu"
    fi
}

require_jq() {
    command -v jq >/dev/null || fail 'jq is required to read GitHub Releases.'
}

# 서명에 쓸 인증서가 유효한지 내려받기 전에 확인한다.
require_signing_identity() {
    /bin/bash "$script_dir/../validate-signing-identity/main.sh" "${SIGNING_IDENTITY:-}"
}

# ── 버전 ─────────────────────────────────────────────────────────────

# 바이너리($1)의 버전을 vX.Y.Z 형식으로 출력한다.
# $(...) 안에서 호출되므로 set -e에 기대지 않고 실패를 직접 반환한다.
read_version() {
    local output
    output=$("$1" version) || return
    if [[ $output =~ ^([Dd]agu[[:space:]]+version[[:space:]]+)?v?([0-9]+\.[0-9]+\.[0-9]+)([[:space:]].*)?$ ]]; then
        printf 'v%s\n' "${BASH_REMATCH[2]}"
    else
        echo "Cannot read the Dagu version: $output" >&2
        return 1
    fi
}

# GitHub Releases에서 최신 안정 릴리스의 버전을 latest에 읽어 둔다.
read_latest() {
    local stable_tag='
        select(.draft == false and .prerelease == false)
        | .tag_name
        | select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))'
    download "$release_api" "$dir/release.json"
    latest=$(jq -er "$stable_tag" "$dir/release.json") \
        || fail 'Cannot read the latest stable release from GitHub Releases.'
}

print_current() {
    if [[ $current == "$latest" ]]; then
        printf 'Dagu - up to date: %s\n' "$current"
    else
        printf 'Dagu - newer than latest: %s\n' "$current"
    fi
}

# ── 코드 서명 ────────────────────────────────────────────────────────

# 바이너리($1)의 서명을 검증하고, 비교에 쓸 서명 정보를 $2.* 파일들로 남긴다.
#   $2.cert-0  서명 인증서
#   $2.dr      designated requirement
snapshot_signature() {
    local binary=$1 prefix=$2
    codesign --verify --strict "$binary" || return
    codesign --display --requirements - "$binary" > "$prefix.requirements" 2> "$prefix.details" || return
    sed -n 's/^designated => //p' "$prefix.requirements" > "$prefix.dr"
    codesign --display --extract-certificates="$prefix.cert-" "$binary" 2>> "$prefix.details" || return
    if [[ ! -s $prefix.dr || ! -s $prefix.cert-0 ]]; then
        echo "Cannot verify a certificate-based code signature: $binary" >&2
        return 1
    fi
}

# 두 서명 정보($1, $2)가 같은 주체인지 확인한다.
# CDHash는 바이너리마다 달라지므로 서명 인증서와 designated requirement를 비교한다.
compare_signatures() {
    local before=$1 after=$2
    if ! cmp -s "$before.cert-0" "$after.cert-0" || ! cmp -s "$before.dr" "$after.dr"; then
        echo 'The signing certificate or designated requirement changed. Update aborted.' >&2
        printf 'Previous certificate SHA-1: %s\n' "$(shasum -a 1 "$before.cert-0" | awk '{print $1}')" >&2
        printf 'New certificate SHA-1: %s\n' "$(shasum -a 1 "$after.cert-0" | awk '{print $1}')" >&2
        printf 'Previous designated requirement: %s\n' "$(cat "$before.dr")" >&2
        printf 'New designated requirement: %s\n' "$(cat "$after.dr")" >&2
        return 1
    fi
}

# ── 설치 단계 ────────────────────────────────────────────────────────

# 최신 릴리스를 내려받아 검증하고 서명해 $dir/dagu로 준비한다. 시스템은 변경하지 않는다.
prepare_binary() {
    local arch asset checksum
    case $(uname -m) in
        arm64) arch=arm64 ;;
        x86_64) arch=amd64 ;;
        *) fail 'Unsupported Mac architecture.' ;;
    esac

    # 1. 아카이브를 내려받아 릴리스의 체크섬과 대조한다.
    asset=dagu_${latest#v}_darwin_$arch.tar.gz
    download "$release/download/$latest/$asset" "$dir/$asset"
    download "$release/download/$latest/checksums.txt" "$dir/checksums.txt"
    checksum=$(awk -v asset="$asset" '$2 == asset {print $1}' "$dir/checksums.txt")
    [[ $checksum =~ ^[[:xdigit:]]{64}$ ]] || fail 'Cannot find the release archive SHA-256 checksum.'
    printf '%s  %s\n' "$checksum" "$dir/$asset" > "$dir/archive.sha256"
    shasum -a 256 -c "$dir/archive.sha256"

    # 2. 아카이브에서 dagu 파일 하나만 푼다. 다른 파일이나 경로는 풀지 않는다.
    tar -xzf "$dir/$asset" -C "$dir" dagu
    [[ -f $dir/dagu && ! -L $dir/dagu ]] || fail 'The release archive does not contain a regular dagu binary.'
    chmod 0755 "$dir/dagu"

    # 3. 서명한 뒤에만 실행한다. 업데이트라면 기존 바이너리와 같은 서명이어야 한다.
    codesign --force --sign "$SIGNING_IDENTITY" --identifier "$identifier" "$dir/dagu"
    snapshot_signature "$dir/dagu" "$dir/signed" || fail 'The downloaded Dagu signature is not valid.'
    if [[ -n $current ]]; then
        compare_signatures "$dir/before" "$dir/signed" || exit 1
    fi
    [[ $(read_version "$dir/dagu") == "$latest" ]] \
        || fail 'The downloaded binary version does not match the release tag.'
}

# 준비한 바이너리로 설치 경로의 바이너리를 교체한다. 여기서부터의 실패는 cleanup이 되돌린다.
replace_binary() {
    local install_dir=${dagu%/*}
    if [[ ! -w $install_dir ]]; then
        use_sudo=true
        sudo -v
        sudo mkdir -p "$install_dir"
    fi

    # 1. 새 바이너리를 같은 디렉토리에 올려 두고, 이전 바이너리를 백업한다.
    stage=$(install_command mktemp "$install_dir/.dagu-new.XXXXXX")
    install_command install -m 0755 "$dir/dagu" "$stage"
    if [[ -n $current ]]; then
        backup=$(install_command mktemp "$install_dir/.dagu-backup.XXXXXX")
        install_command cp -p "$dagu" "$backup"
    fi

    # 2. 서비스를 내리고 바이너리를 한 번의 mv로 교체한다.
    if [[ $service_was_loaded == true ]]; then
        service_touched=true
        launchctl bootout "$service_target"
    fi
    binary_replaced=true
    install_command mv -f "$stage" "$dagu"
    stage=

    # 3. 설치된 바이너리가 준비한 것과 같은 서명·버전인지 다시 확인한다.
    snapshot_signature "$dagu" "$dir/installed" || fail 'The installed Dagu signature is not valid.'
    compare_signatures "$dir/signed" "$dir/installed" || exit 1
    if [[ -n $current ]]; then
        compare_signatures "$dir/before" "$dir/installed" || exit 1
    fi
    [[ $(read_version "$dagu") == "$latest" ]] \
        || fail 'The installed Dagu version does not match the release tag.'
}

# setup에서 host와 port로 LaunchAgent plist를 만든다.
write_launchagent() {
    # 서비스에는 실행에 필요한 환경 변수만 넘긴다. SIGNING_IDENTITY 같은 값은 넣지 않는다.
    local agent='{
        Label: $label,
        ProgramArguments: [$dagu, "start-all", "--host", $host, "--port", $port],
        WorkingDirectory: $home,
        RunAtLoad: true,
        KeepAlive: true,
        EnvironmentVariables: (env | with_entries(select(
            .key == "HOME" or .key == "PATH" or .key == "DAGU_HOME"
            or .key == "XDG_CONFIG_HOME" or .key == "XDG_DATA_HOME" or .key == "XDG_STATE_HOME"
        ))),
        StandardOutPath: ($log_dir + "/stdout.log"),
        StandardErrorPath: ($log_dir + "/stderr.log")
    }'
    jq -n --arg label "$label" --arg dagu "$dagu" --arg host "$host" --arg port "$port" \
        --arg home "$HOME" --arg log_dir "$log_dir" "$agent" > "$dir/agent.json"
    plutil -convert xml1 -o "$dir/agent.plist" "$dir/agent.json"
    plutil -lint "$dir/agent.plist"
    plist_created=true
    install -m 0644 "$dir/agent.plist" "$plist"
    echo "Registered the LaunchAgent: $plist"
}

# 서비스가 떠 있게 하고, 뜬 뒤에도 유지되는지 확인한다.
ensure_launchagent() {
    local i state running=0
    mkdir -p "$HOME/Library/LaunchAgents" "$log_dir"
    if [[ $mode == setup ]]; then
        write_launchagent
    fi

    # 등록되지 않았으면 등록하고, 등록됐지만 멈춰 있으면 시작한다. 이미 실행 중이면 건드리지 않는다.
    if ! state=$(launchctl print "$service_target" 2>/dev/null); then
        service_touched=true
        bootstrap_launchagent
    elif ! [[ $state =~ state[[:space:]]*=[[:space:]]*running ]]; then
        service_touched=true
        launchctl kickstart "$service_target"
    fi

    # 시작 직후 죽는 경우를 걸러내기 위해 연속 2회 running이어야 성공으로 본다.
    for i in {1..10}; do
        state=$(launchctl print "$service_target")
        if [[ $state =~ state[[:space:]]*=[[:space:]]*running ]]; then
            running=$((running + 1))
            if (( running >= 2 )); then
                return 0
            fi
        else
            running=0
        fi
        sleep 1
    done
    fail "Dagu did not stay running. Check the logs: $log_dir"
}

# 되돌리기에 필요하므로 시작 시점의 서비스 등록 여부를 기록한다.
record_service_state() {
    if launchctl print "$service_target" >/dev/null 2>&1; then
        service_was_loaded=true
    fi
}

# ── 서브커맨드 ───────────────────────────────────────────────────────

cmd_check() {
    (( $# == 0 )) || usage_error 'check-dagu-update'
    mode=check

    # 미설치: 설치 명령을 안내한다.
    if ! is_installed; then
        printf '[Setup] setup-dagu 0.0.0.0 8040\n[Setup] setup-dagu 127.0.0.1 8040\n'
        exit "$EXIT_NOT_INSTALLED"
    fi
    require_executable
    require_jq
    create_workdir

    current=$(read_version "$dagu")
    read_latest
    if version_is_newer "$latest" "$current"; then
        printf '[Update %s → %s] update-dagu\n' "$current" "$latest"
        exit "$EXIT_UPDATE_AVAILABLE"
    fi
    print_current
}

cmd_setup() {
    (( $# == 2 )) || usage_error 'setup-dagu <host> <port>'
    mode=setup
    host=$1
    port=$2
    if [[ -z $host || $host == -* || $host == *[[:space:]]* ]]; then
        echo 'Specify a host without whitespace or command-line flags.' >&2
        exit 2
    fi
    if [[ ! $port =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
        echo 'Specify a port from 1 to 65535.' >&2
        exit 2
    fi
    port=$((10#$port))

    # 이미 설치되어 있으면 인증서 확인보다 중복 설치 오류를 먼저 보여준다.
    if is_installed; then
        fail 'Dagu is already installed. Use update-dagu to update it.'
    fi
    if [[ -e $plist ]]; then
        fail "Dagu is already configured. LaunchAgent: $plist"
    fi
    require_jq
    require_signing_identity
    create_workdir

    read_latest
    record_service_state
    echo "Installing Dagu $latest."
    prepare_binary
    replace_binary
    ensure_launchagent
    committed=true
    echo "Installed Dagu $latest and started the start-all service."
}

cmd_update() {
    (( $# == 0 )) || usage_error 'update-dagu'
    mode=update

    if ! is_installed; then
        fail 'Dagu is not installed. Run setup-dagu <host> <port> first.'
    fi
    require_executable
    if [[ ! -f $plist ]]; then
        fail "Dagu LaunchAgent configuration is missing: $plist"
    fi
    require_jq
    require_signing_identity
    create_workdir

    # 기존 바이너리는 서명을 확인한 뒤에만 실행한다. 이 서명이 새 바이너리의 비교 기준이 된다.
    snapshot_signature "$dagu" "$dir/before" || fail 'The existing Dagu signature is not valid.'
    current=$(read_version "$dagu")
    read_latest
    record_service_state

    # 이미 최신이면 바이너리는 두고 서비스가 떠 있는지만 확인한다.
    if ! version_is_newer "$latest" "$current"; then
        print_current
        ensure_launchagent
        committed=true
        return 0
    fi

    echo "Updating Dagu $current → $latest."
    prepare_binary
    replace_binary
    ensure_launchagent
    committed=true
    echo "Installed Dagu $latest and started the start-all service."
}

main() {
    local subcommand=${1:-}
    shift || true
    case $subcommand in
        check) cmd_check "$@" ;;
        setup) cmd_setup "$@" ;;
        update) cmd_update "$@" ;;
        *) usage_error 'main.sh <check | setup <host> <port> | update>' ;;
    esac
}

main "$@"
