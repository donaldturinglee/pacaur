#!/usr/bin/env bash
set -euo pipefail

repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
program="$repository/pacaur"
bash_command=$(command -v bash)
timeout_command=$(command -v timeout)
script_command=$(command -v script)
rm_command=$(command -v rm)
original_path=$PATH
test_parent=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
test_dir=$(mktemp -d "$test_parent/pacaur-remove-tests.XXXXXXXX")
checks=0

cleanup() {
    case "$test_dir" in
        "$test_parent"/pacaur-remove-tests.*) rm -rf -- "$test_dir" ;;
        *) printf 'Unexpected test directory: %s\n' "$test_dir" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    for stream in stdout stderr; do
        if [[ -s $test_dir/$stream ]]; then
            printf '%s\n' "$(< "$test_dir/$stream")" >&2
        fi
    done
    exit 1
}

mkdir "$test_dir/bin" "$test_dir/pacman-only" "$test_dir/empty"
export PACAUR_TEST_RECORD="$test_dir/record"
export PACAUR_TEST_INSTALLED="$test_dir/installed"
printf '%s\n' example example-doc 'libfoo++@1_2.3' shared-dep dependant > "$PACAUR_TEST_INSTALLED"
printf 'y\n' > "$test_dir/yes"
printf 'n\n' > "$test_dir/no"
printf 'fixture-answer\ny\n' > "$test_dir/terminal-yes"
printf 'existing build log\n' > "$test_dir/build.log"
printf 'existing package artifact\n' > "$test_dir/example.pkg.tar.zst"
sha256sum "$test_dir/build.log" "$test_dir/example.pkg.tar.zst" > "$test_dir/hashes"

cat > "$test_dir/bin/pacman" <<'MOCK'
#!/bin/bash
case $1 in
    -Qq)
        printf 'query\n' >> "$PACAUR_TEST_RECORD.events"
        printf '%s\0' "$@" > "$PACAUR_TEST_RECORD.query"
        printf '%s\n' "$EUID" > "$PACAUR_TEST_RECORD.query-uid"
        [[ ${PACAUR_TEST_VIA_SUDO:-0} == 0 && $2 == -- ]] || exit 96
        shift 2
        if [[ ${PACAUR_TEST_QUERY_STATUS:-0} != 0 ]]; then
            printf 'mock local database error\n' >&2
            exit "$PACAUR_TEST_QUERY_STATUS"
        fi
        mapfile -t installed < "$PACAUR_TEST_INSTALLED"
        status=0
        for target in "$@"; do
            # Real pacman queries also resolve virtual provider names.
            if [[ $target == virtual-example ]]; then
                printf 'example\n'
                continue
            fi
            found=0
            for name in "${installed[@]}"; do
                if [[ $target == "$name" ]]; then
                    printf '%s\n' "$name"
                    found=1
                    break
                fi
            done
            if (( ! found )); then
                printf 'mock package not found: %s\n' "$target" >&2
                status=1
            fi
        done
        exit "$status"
        ;;
    -R)
        printf 'remove\n' >> "$PACAUR_TEST_RECORD.events"
        printf '%s\0' "$@" > "$PACAUR_TEST_RECORD.remove"
        printf '%s\n' "${PACAUR_TEST_VIA_SUDO:-0}" > "$PACAUR_TEST_RECORD.remove-sudo"
        [[ $2 == -- ]] || exit 97
        shift 2
        if [[ ${PACAUR_TEST_REQUIRE_TTY:-0} == 1 ]]; then
            [[ -t 0 && -t 1 && -t 2 ]] || exit 98
        fi
        if [[ -n ${PACAUR_TEST_GROUP_SIGNAL:-} ]]; then
            read -r group < <(ps -o pgid= -p "$$")
            kill -s "$PACAUR_TEST_GROUP_SIGNAL" -- "-$group"
            exit 99
        fi
        if [[ $# == 1 && $1 == shared-dep ]]; then
            printf 'removing shared-dep breaks dependency required by dependant\n' >&2
            exit 1
        fi
        printf 'Remove these packages? [Y/n] ' >&2
        IFS= read -r answer || exit 1
        printf '%s\n' "$answer" > "$PACAUR_TEST_RECORD.answer"
        if [[ $answer == n ]]; then
            printf 'removal cancelled\n'
            exit 1
        fi
        printf 'removal output\n'
        if [[ ${PACAUR_TEST_REMOVE_STATUS:-0} != 0 ]]; then
            printf 'mock removal diagnostic\n' >&2
            exit "$PACAUR_TEST_REMOVE_STATUS"
        fi
        : > "$PACAUR_TEST_RECORD.removed"
        ;;
    *) printf 'Unexpected pacman operation: %s\n' "$1" >&2; exit 95 ;;
esac
MOCK
cat > "$test_dir/bin/sudo" <<'MOCK'
#!/bin/bash
printf 'sudo\n' >> "$PACAUR_TEST_RECORD.events"
printf '%s\0' "$@" > "$PACAUR_TEST_RECORD.sudo"
if [[ ${PACAUR_TEST_AUTH_TTY:-0} == 1 ]]; then
    exec 3<> /dev/tty || exit 1
    printf 'Test authentication answer: ' >&3
    IFS= read -rs answer <&3 || exit 1
    printf '\n' >&3
    [[ $answer == fixture-answer ]] || exit 1
    : > "$PACAUR_TEST_RECORD.tty-auth"
fi
if [[ ${PACAUR_TEST_SUDO_STATUS:-0} != 0 ]]; then
    printf 'mock sudo authentication error\n' >&2
    exit "$PACAUR_TEST_SUDO_STATUS"
fi
[[ $1 == -- && $2 == pacman ]] || exit 94
shift
export PACAUR_TEST_VIA_SUDO=1
exec "$@"
MOCK
chmod +x "$test_dir/bin/pacman" "$test_dir/bin/sudo"
ln -s "$test_dir/bin/pacman" "$test_dir/pacman-only/pacman"
export PATH="$test_dir/bin:$original_path"

check() {
    local expected=$1 error_text=$2 actual=0 terminal_command output
    shift 2
    "$rm_command" -f -- "$PACAUR_TEST_RECORD".*
    if [[ ${PACAUR_TEST_TERMINAL:-0} == 1 ]]; then
        printf -v terminal_command '%q ' "$bash_command" "$program" "$@"
        "$timeout_command" --kill-after=2 10 "$script_command" --quiet --return --echo never \
            --command "exec $terminal_command" /dev/null \
            < "${PACAUR_TEST_INPUT:-$test_dir/yes}" > "$test_dir/stdout" 2> "$test_dir/stderr" || actual=$?
        output=$(< "$test_dir/stdout")
        printf '%s\n' "${output//$'\r'/}" > "$test_dir/stdout"
    else
        "$timeout_command" --kill-after=2 10 "$bash_command" "$program" "$@" \
            < "${PACAUR_TEST_INPUT:-$test_dir/yes}" > "$test_dir/stdout" 2> "$test_dir/stderr" || actual=$?
    fi
    [[ $actual == "$expected" ]] || fail "expected status $expected, got $actual for $*"
    [[ $(< "$test_dir/stderr") == *"$error_text"* || $(< "$test_dir/stdout") == *"$error_text"* ]] \
        || fail "missing error '$error_text' for $*"
    ((checks += 1))
}

no_removal() {
    [[ ! -e $PACAUR_TEST_RECORD.remove && ! -e $PACAUR_TEST_RECORD.sudo ]] \
        || fail 'invalid targets requested removal or sudo'
}

assert_arguments() {
    local record=$1 index
    shift
    local -a actual expected=("$@")
    [[ -s $record ]] || fail "missing invocation record: $record"
    mapfile -d '' -t actual < "$record"
    [[ ${#actual[@]} == ${#expected[@]} ]] || fail "wrong argument count in $record"
    for ((index=0; index<${#expected[@]}; index++)); do
        [[ ${actual[index]} == "${expected[index]}" ]] || fail "wrong argument $index in $record"
    done
}

assert_removal() {
    assert_arguments "$PACAUR_TEST_RECORD.query" -Qq -- "$@"
    assert_arguments "$PACAUR_TEST_RECORD.remove" -R -- "$@"
    [[ $(< "$PACAUR_TEST_RECORD.query-uid") == "$EUID" ]] || fail 'query changed privileges'
    if (( EUID == 0 )); then
        [[ ! -e $PACAUR_TEST_RECORD.sudo ]] || fail 'root invoked sudo'
        [[ $(< "$PACAUR_TEST_RECORD.remove-sudo") == 0 ]] || fail 'root did not remove directly'
        [[ $(< "$PACAUR_TEST_RECORD.events") == $'query\nremove' ]] || fail 'wrong transaction order/count'
    else
        assert_arguments "$PACAUR_TEST_RECORD.sudo" -- pacman -R -- "$@"
        [[ $(< "$PACAUR_TEST_RECORD.remove-sudo") == 1 ]] || fail 'non-root removal bypassed sudo'
        [[ $(< "$PACAUR_TEST_RECORD.events") == $'query\nsudo\nremove' ]] || fail 'wrong transaction order/count'
    fi
}

check 0 '' -h
[[ $(< "$test_dir/stdout") == *'-R PACKAGE...'* ]] || fail 'help omits removal'
PATH="$test_dir/empty" check 2 'at least one installed package name' -R
for target in '' - -h --noconfirm --syncdeps .example local/example './example' \
    'example>=1' 'example doc' $'example\nexample-doc' 'example*' 'example;true'; do
    PATH="$test_dir/empty" check 2 'requires exact package names' -R example "$target"
    no_removal
    [[ ! -e $PACAUR_TEST_RECORD.query ]] || fail 'argument error queried packages'
done
check 2 'unsupported arguments' -Rs example
no_removal
PATH="$test_dir/empty" check 1 'Required command not found: pacman' -R example
no_removal

for target in missing example-group; do
    check 1 'Installed package validation failed (pacman exit status 1)' -R example "$target"
    assert_arguments "$PACAUR_TEST_RECORD.query" -Qq -- example "$target"
    no_removal
    [[ $(< "$test_dir/stderr") == *"mock package not found: $target"* ]] || fail 'lost original query error'
    [[ ! -s $test_dir/stdout ]] || fail 'query leaked metadata'
done
check 1 'requires exact installed package names' -R example virtual-example
assert_arguments "$PACAUR_TEST_RECORD.query" -Qq -- example virtual-example
no_removal
[[ ! -s $test_dir/stdout ]] || fail 'provider query leaked metadata'
for status in 2 129 130 143; do
    expected=$status
    (( status == 2 )) && expected=1
    PACAUR_TEST_QUERY_STATUS=$status check "$expected" "pacman exit status $status" -R example
    no_removal
    [[ $(< "$test_dir/stderr") == *'mock local database error'* ]] || fail 'lost database error'
done

# Only pacman and, for non-root callers, sudo are required.
PATH="$test_dir/bin" check 0 '' -R example
assert_removal example
[[ $(< "$test_dir/stdout") == 'removal output' ]] || fail 'removal stdout changed or metadata leaked'
[[ $(< "$test_dir/stderr") == 'Remove these packages? [Y/n] ' ]] || fail 'confirmation prompt changed'
[[ $(< "$PACAUR_TEST_RECORD.answer") == y ]] || fail 'stdin was not forwarded'
check 0 '' -R example example-doc 'libfoo++@1_2.3'
assert_removal example example-doc 'libfoo++@1_2.3'
check 0 '' -R example example
assert_removal example example

check 1 'breaks dependency required by dependant' -R shared-dep
assert_removal shared-dep
[[ ! -e $PACAUR_TEST_RECORD.removed ]] || fail 'ignored dependency protection'
check 0 '' -R shared-dep dependant
assert_removal shared-dep dependant

PACAUR_TEST_INPUT="$test_dir/no" check 1 'Package removal failed (exit status 1)' -R example example-doc
assert_removal example example-doc
[[ $(< "$test_dir/stdout") == 'removal cancelled' ]] || fail 'cancellation claimed success'
[[ ! -e $PACAUR_TEST_RECORD.removed ]] || fail 'removed after cancellation'
PACAUR_TEST_INPUT=/dev/null check 1 'Package removal failed (exit status 1)' -R example
[[ ! -e $PACAUR_TEST_RECORD.removed ]] || fail 'removed after EOF'
for status in 1 4 42 129 130 143; do
    expected=1
    (( status >= 129 )) && expected=$status
    PACAUR_TEST_REMOVE_STATUS=$status check "$expected" "exit status $status" -R example
    [[ $(< "$test_dir/stderr") == *'mock removal diagnostic'* ]] || fail 'lost original removal error'
    [[ $(< "$test_dir/stdout") == 'removal output' ]] || fail 'lost removal progress'
done

PACAUR_TEST_TERMINAL=1 PACAUR_TEST_REQUIRE_TTY=1 check 0 '' -R example
assert_removal example
for signal in HUP INT TERM; do
    case $signal in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    PACAUR_TEST_TERMINAL=1 PACAUR_TEST_GROUP_SIGNAL=$signal check "$expected" '' -R example
    [[ ! -e $PACAUR_TEST_RECORD.removed ]] || fail 'removed after terminal interruption'
done
if (( EUID != 0 )); then
    PATH="$test_dir/pacman-only" check 1 'Required command not found: sudo' -R example
    no_removal
    for status in 1 126 130; do
        expected=1
        (( status == 130 )) && expected=130
        PACAUR_TEST_SUDO_STATUS=$status check "$expected" "exit status $status" -R example
        [[ ! -e $PACAUR_TEST_RECORD.remove ]] || fail 'sudo failure still requested removal'
        [[ $(< "$test_dir/stderr") == *'mock sudo authentication error'* ]] || fail 'lost sudo error'
    done
    PACAUR_TEST_TERMINAL=1 PACAUR_TEST_AUTH_TTY=1 PACAUR_TEST_INPUT="$test_dir/terminal-yes" \
        check 0 '' -R example
    assert_removal example
    [[ -e $PACAUR_TEST_RECORD.tty-auth ]] || fail 'authentication lost the controlling terminal'
else
    PATH="$test_dir/pacman-only" check 0 '' -R example
    assert_removal example
fi
sha256sum --check --status "$test_dir/hashes" || fail 'changed package artifacts or logs'
printf 'Passed %d removal checks (uid %s).\n' "$checks" "$EUID"

if (( EUID == 0 )); then
    PATH="$original_path" runuser -u nobody -- "$bash_command" "$repository/tests/remove.sh"
fi
