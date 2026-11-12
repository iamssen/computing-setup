#!/bin/bash
# Node.js 공식 pkg의 버전 확인과 설치. main.fish의 명령들이 서브커맨드로 호출한다.
#   main.sh current                       설치된 버전을 출력한다 (미설치면 출력 없음)
#   main.sh check                         업데이트 가능 여부를 출력한다
#   main.sh install <release-directory>   공식 pkg를 내려받아 검증하고 설치한다
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../_shared/lib.sh"

release=https://nodejs.org/download/release
# 공식 pkg가 설치하는 경로. 환경 변수는 테스트에서 경로를 바꾸는 용도로만 쓴다.
node=${COMPUTING_SETUP_NODE_BIN:-/usr/local/bin/node}
version_pattern='^v([0-9]+)\.([0-9]+)\.([0-9]+)$'
# 설치된 버전(vX.Y.Z). 미설치면 빈 문자열이다. read_current가 채운다.
current=
# 임시 작업 디렉토리. create_workdir가 채운다.
dir=

# 설치된 Node.js의 버전을 current에 읽어 둔다.
read_current() {
    if [[ -x $node ]]; then
        current=$("$node" --version)
        if ! [[ $current =~ $version_pattern ]]; then
            fail "Cannot read the installed Node.js version: $current"
        fi
    fi
}

# 임시 작업 디렉토리를 만들고, 어떤 경로로 종료하든 지워지게 한다.
create_workdir() {
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# 릴리스 디렉토리($1)의 체크섬 목록을 파일($2)로 내려받고, 그 안의 macOS pkg 버전을 출력한다.
# $(...) 안에서 호출되므로 set -e에 기대지 않고 실패를 직접 반환한다.
read_release() {
    local channel=$1 manifest=$2 package version
    download "$release/$channel/SHASUMS256.txt" "$manifest" || return
    package=$(awk '$2 ~ /^node-v[0-9]+\.[0-9]+\.[0-9]+\.pkg$/ {print $2}' "$manifest")
    version=${package#node-}
    version=${version%.pkg}
    if ! [[ $version =~ $version_pattern ]]; then
        echo "Cannot find a macOS package in release directory: $channel" >&2
        return 1
    fi
    # 디렉토리 이름이 약속하는 버전과 실제 내용이 다르면 거부한다.
    if [[ $channel == v* && $version != "$channel" ]]; then
        echo "Release directory $channel contains a different version: $version" >&2
        return 1
    fi
    if [[ $channel =~ ^latest-v([0-9]+)\.x$ && $version != v"${BASH_REMATCH[1]}".* ]]; then
        echo "Release directory $channel contains a different major version: $version" >&2
        return 1
    fi
    printf '%s\n' "$version"
}

cmd_current() {
    (( $# == 0 )) || usage_error 'main.sh current'
    read_current
    if [[ -n $current ]]; then
        printf '%s\n' "$current"
    fi
}

cmd_check() {
    (( $# == 0 )) || usage_error 'check-node-update'
    local latest current_major latest_major same_major_latest= updates=false
    read_current
    create_workdir

    latest=$(read_release latest "$dir/SHASUMS256.txt")
    # 미설치: 최신 버전 설치를 안내한다.
    if [[ -z $current ]]; then
        printf '[Install %s] install-node latest\n' "$latest"
        exit "$EXIT_NOT_INSTALLED"
    fi

    current_major=${current#v}
    current_major=${current_major%%.*}
    latest_major=${latest#v}
    latest_major=${latest_major%%.*}
    # 설치된 메이저가 최신 메이저보다 앞서 있으면 비교할 릴리스 디렉토리가 없다.
    if (( latest_major >= current_major )); then
        same_major_latest=$(read_release "latest-v$current_major.x" "$dir/same-major.sha256")
    fi

    # 같은 메이저 안의 업데이트와 메이저 업그레이드를 따로 안내한다.
    if [[ -n $same_major_latest ]] && version_is_newer "$same_major_latest" "$current"; then
        printf '[Update %s → %s] install-node latest-v%s.x\n' "$current" "$same_major_latest" "$current_major"
        updates=true
    fi
    if (( latest_major > current_major )); then
        printf '[Update %s → %s] install-node latest\n' "$current" "$latest"
        updates=true
    fi
    if [[ $updates == true ]]; then
        exit "$EXIT_UPDATE_AVAILABLE"
    fi

    if [[ $current == "$latest" ]]; then
        printf 'Node.js - up to date: %s\n' "$current"
    else
        printf 'Node.js - newer than latest: %s\n' "$current"
    fi
}

cmd_install() {
    (( $# == 1 )) || usage_error 'install-node <release-directory> (e.g. latest, v26.3.0, latest-v26.x)'
    local selector=$1 manifest target pkg checksum installed
    if ! [[ $selector =~ ^(latest(-[a-z0-9.-]+)?|v[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        echo "Invalid release directory: $selector. Use latest, v26.3.0, or latest-v26.x." >&2
        exit 2
    fi
    read_current
    create_workdir

    # 1. 선택한 릴리스 디렉토리가 가리키는 실제 버전을 확인한다.
    manifest=$dir/SHASUMS256.txt
    target=$(read_release "$selector" "$manifest")
    if [[ $current == "$target" ]]; then
        printf 'Node.js %s is already installed.\n' "$current"
        return 0
    fi
    if [[ -n $current ]]; then
        printf 'Installing Node.js %s → %s (%s).\n' "$current" "$target" "$selector"
    else
        printf 'Installing Node.js %s (%s).\n' "$target" "$selector"
    fi

    # 2. pkg를 내려받는다. latest 같은 별칭 대신 바뀌지 않는 버전 디렉토리에서 받는다.
    pkg=node-$target.pkg
    checksum=$(awk -v pkg="$pkg" '$2 == pkg {print $1}' "$manifest")
    if ! [[ $checksum =~ ^[[:xdigit:]]{64}$ ]]; then
        fail 'Cannot find a SHA-256 checksum for the macOS package.'
    fi
    download "$release/$target/$pkg" "$dir/$pkg"

    # 3. 체크섬과 pkg 서명을 검증한 뒤에만 설치한다.
    printf '%s  %s\n' "$checksum" "$dir/$pkg" > "$dir/package.sha256"
    shasum -a 256 -c "$dir/package.sha256"
    pkgutil --check-signature "$dir/$pkg"
    sudo /usr/sbin/installer -pkg "$dir/$pkg" -target /

    # 4. 실제로 설치된 버전이 선택한 버전인지 확인한다.
    installed=$("$node" --version)
    if [[ $installed != "$target" ]]; then
        fail "Installed Node.js version ($installed) does not match the selected release ($target)."
    fi
    printf 'Installed Node.js %s.\n' "$installed"
}

main() {
    local subcommand=${1:-}
    shift || true
    case $subcommand in
        current) cmd_current "$@" ;;
        check) cmd_check "$@" ;;
        install) cmd_install "$@" ;;
        *) usage_error 'main.sh <current | check | install <release-directory>>' ;;
    esac
}

main "$@"
