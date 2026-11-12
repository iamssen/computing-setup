# 이 저장소의 fish 명령들을 등록하는 로더.
# 처음 한 번만 `source functions.fish`로 직접 읽는다. 그때 fish의 conf.d에 이 파일의 심볼릭 링크가
# 만들어지고, 이후의 셸에서는 fish가 그 링크를 통해 자동으로 읽는다.

# 링크를 거쳐 실행되어도 저장소의 실제 경로를 기준으로 삼는다.
set -l loader (path resolve (status filename))

# 1. 각 모듈의 진입점(functions/<모듈>/main.fish)을 모두 읽는다.
for function_entry in (path dirname $loader)/functions/*/main.fish
    source $function_entry
    or return $status
end

# 2. conf.d에 연결한다. 스크립트나 테스트가 설정을 바꾸지 않도록 대화형 셸에서만 한다.
status is-interactive
or return 0

set -l conf_dir $__fish_config_dir/conf.d
# 링크 이름과 상관없이, 이 파일을 가리키는 항목이 있으면 이미 연결된 것이다.
# conf.d의 링크를 통해 읽히는 평소의 셸 시작은 여기서 끝난다.
for entry in $conf_dir/*.fish
    if test (path resolve $entry) = $loader
        return 0
    end
end

set -l link $conf_dir/computing-setup.fish
# 같은 이름의 다른 파일(깨진 링크 포함)은 덮어쓰지 않는다.
if test -e $link; or test -L $link
    echo "computing-setup: $link already exists and does not point to $loader." >&2
    return 1
end

if mkdir -p $conf_dir; and ln -s $loader $link
    echo "computing-setup: linked $link → $loader"
else
    echo "computing-setup: failed to link $loader into $conf_dir." >&2
    return 1
end
