#!/usr/bin/env bash
set -euo pipefail

repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
program="$repository/pacaur"
bash_command=$(command -v bash)
timeout_command=$(command -v timeout)
rm_command=$(command -v rm)
original_path=$PATH
test_parent=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
test_dir=$(mktemp -d "$test_parent/pacaur-install-tests.XXXXXXXX")
checks=0

cleanup() {
    case "$test_dir" in
        "$test_parent"/pacaur-install-tests.*) rm -rf -- "$test_dir" ;;
        *) printf 'Unexpected test directory: %s\n' "$test_dir" >&2; return 1 ;;
    esac
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    if [[ -s "$test_dir/stderr" ]]; then
        printf '%s\n' "$(< "$test_dir/stderr")" >&2
    fi
    exit 1
}

mkdir "$test_dir/bin" "$test_dir/pacman-only" "$test_dir/empty" "$test_dir/package output"
export PACAUR_TEST_RECORD="$test_dir/record"
package="$test_dir/package output/example-1-1-any.pkg.tar.zst"
second_package="$test_dir/package output/example-doc.custom"
special_package="$test_dir/"'package $name; literal.artifact'
printf 'valid package\n' > "$package"
printf 'valid documentation package\n' > "$second_package"
printf 'valid package\n' > "$special_package"
printf 'valid package\n' > "$test_dir/-leading-dash"
printf 'invalid package\n' > "$test_dir/invalid.pkg.tar.zst"
printf 'existing build log\n' > "$test_dir/build.log"
printf 'y\n' > "$test_dir/yes"
printf 'n\n' > "$test_dir/no"
ln -s "$package" "$test_dir/package-link"
ln -s "$test_dir/missing" "$test_dir/broken-link"
mkfifo "$test_dir/pipe"
sha256sum "$package" "$second_package" "$special_package" "$test_dir/build.log" > "$test_dir/hashes"

cat > "$test_dir/bin/pacman" <<'MOCK'
#!/bin/bash
case $1 in
    -Qp)
        printf '%s\0' "$@" > "$PACAUR_TEST_RECORD.query"
        printf '%s\n' "$EUID" > "$PACAUR_TEST_RECORD.query-uid"
        [[ ${PACAUR_TEST_VIA_SUDO:-0} == 0 ]] || exit 95
        [[ $2 == -- ]] || exit 96
        shift 2
        if [[ ${PACAUR_TEST_QUERY_STATUS:-0} != 0 ]]; then
            printf 'mock package validation error\n' >&2
            exit "$PACAUR_TEST_QUERY_STATUS"
        fi
        for package in "$@"; do
            IFS= read -r contents < "$package" || exit 97
            if [[ $contents == 'invalid package' ]]; then
                printf 'mock invalid package: %s\n' "$package" >&2
                exit 1
            fi
        done
        printf 'metadata query output\n'
        ;;
    -U)
        printf '%s\0' "$@" > "$PACAUR_TEST_RECORD.install"
        printf '%s\n' "${PACAUR_TEST_VIA_SUDO:-0}" > "$PACAUR_TEST_RECORD.install-sudo"
        printf 'Install these packages? [Y/n] ' >&2
        IFS= read -r answer || exit 1
        printf '%s\n' "$answer" > "$PACAUR_TEST_RECORD.answer"
        if [[ $answer == n ]]; then
            printf 'installation cancelled\n'
            exit 1
        fi
        printf 'installation output\n'
        printf 'installation diagnostic\n' >&2
        exit "${PACAUR_TEST_INSTALL_STATUS:-0}"
        ;;
    *) printf 'Unexpected pacman operation: %s\n' "$1" >&2; exit 98 ;;
esac
MOCK
cat > "$test_dir/bin/sudo" <<'MOCK'
#!/bin/bash
printf '%s\0' "$@" > "$PACAUR_TEST_RECORD.sudo"
if [[ ${PACAUR_TEST_SUDO_STATUS:-0} != 0 ]]; then
    printf 'mock sudo authentication error\n' >&2
    exit "$PACAUR_TEST_SUDO_STATUS"
fi
[[ $1 == -- ]] || exit 99
shift
export PACAUR_TEST_VIA_SUDO=1
exec "$@"
MOCK
chmod +x "$test_dir/bin/pacman" "$test_dir/bin/sudo"
ln -s "$test_dir/bin/pacman" "$test_dir/pacman-only/pacman"
export PATH="$test_dir/bin:$original_path"

check() {
    local expected_status=$1 expected_error=$2 actual_status=0
    shift 2
    "$rm_command" -f -- "$PACAUR_TEST_RECORD.query" "$PACAUR_TEST_RECORD.install" "$PACAUR_TEST_RECORD.sudo"
    "$timeout_command" --kill-after=2 10 "$bash_command" "$program" "$@" \
        < "${PACAUR_TEST_INPUT:-$test_dir/yes}" > "$test_dir/stdout" 2> "$test_dir/stderr" || actual_status=$?
    [[ $actual_status == "$expected_status" ]] || fail "expected status $expected_status, got $actual_status for $*"
    if [[ -n $expected_error ]]; then
        [[ $(< "$test_dir/stderr") == *"$expected_error"* ]] || fail "missing error '$expected_error' for $*"
    fi
    ((checks += 1))
}

no_install() {
    [[ ! -e $PACAUR_TEST_RECORD.install && ! -e $PACAUR_TEST_RECORD.sudo ]] \
        || fail 'validation failure requested installation or sudo'
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

assert_install() {
    assert_arguments "$PACAUR_TEST_RECORD.query" -Qp -- "$@"
    assert_arguments "$PACAUR_TEST_RECORD.install" -U -- "$@"
    [[ $(< "$PACAUR_TEST_RECORD.query-uid") == "$EUID" ]] || fail 'validation changed privileges'
    if (( EUID == 0 )); then
        [[ ! -e $PACAUR_TEST_RECORD.sudo ]] || fail 'root invoked sudo'
        [[ $(< "$PACAUR_TEST_RECORD.install-sudo") == 0 ]] || fail 'root did not install directly'
    else
        assert_arguments "$PACAUR_TEST_RECORD.sudo" -- pacman -U -- "$@"
        [[ $(< "$PACAUR_TEST_RECORD.install-sudo") == 1 ]] || fail 'non-root installation bypassed sudo'
    fi
}

check 0 '' -h
[[ $(< "$test_dir/stdout") == *'-U FILE...'* ]] || fail 'help omits installation'
check 2 '-U requires at least one local package file' -U
check 2 'not empty arguments or options' -U ''
check 2 'not empty arguments or options' -U "$package" ''
check 2 'not empty arguments or options' -U -h
check 2 'not empty arguments or options' -U "$package" --noconfirm
no_install
[[ ! -e $PACAUR_TEST_RECORD.query ]] || fail 'argument error queried packages'

for target in "$test_dir/missing" "$test_dir/empty" "$test_dir/pipe" \
    "$test_dir/broken-link" 'https://example.invalid/package.pkg.tar.zst'; do
    check 1 'readable local file' -U "$target"
    no_install
    [[ ! -e $PACAUR_TEST_RECORD.query ]] || fail 'invalid file reached pacman'
done
check 1 'readable local file' -U "$package" "$test_dir/missing"
no_install
[[ ! -e $PACAUR_TEST_RECORD.query ]] || fail 'did not check every file before querying'

PATH="$test_dir/empty" check 1 'Required command not found: pacman' -U "$package"
no_install
if (( EUID != 0 )); then
    PATH="$test_dir/pacman-only" check 1 'Required command not found: sudo' -U "$package"
    no_install
    chmod 000 "$second_package"
    check 1 'readable local file' -U "$package" "$second_package"
    chmod 600 "$second_package"
    no_install
fi

check 1 'Package validation failed (pacman exit status 1)' -U "$package" "$test_dir/invalid.pkg.tar.zst"
no_install
[[ $(< "$test_dir/stderr") == *'mock invalid package'* ]] || fail 'validation lost original error'
[[ ! -s $test_dir/stdout ]] || fail 'validation leaked metadata'
for status in 2 129 130 143; do
    expected=$status
    (( status == 2 )) && expected=1
    PACAUR_TEST_QUERY_STATUS=$status check "$expected" "pacman exit status $status" -U "$package"
    no_install
done

# No query/build dependencies are needed; all targets share one installation call.
PATH="$test_dir/bin" check 0 '' -U "$package"
assert_install "$package"
[[ $(< "$test_dir/stdout") == 'installation output' ]] || fail 'install stdout changed or metadata leaked'
[[ $(< "$test_dir/stderr") == *'Install these packages? [Y/n]'* ]] || fail 'confirmation prompt was lost'
[[ $(< "$PACAUR_TEST_RECORD.answer") == y ]] || fail 'stdin was not forwarded'
check 0 '' -U "$package" "$second_package" "$special_package"
assert_install "$package" "$second_package" "$special_package"
check 0 '' -U "$test_dir/package-link"
assert_install "$test_dir/package-link"
caller_directory=$PWD
cd -- "$test_dir"
check 0 '' -U './package output/example-1-1-any.pkg.tar.zst' './-leading-dash'
assert_install "$test_dir/./package output/example-1-1-any.pkg.tar.zst" "$test_dir/./-leading-dash"
cd -- "$caller_directory"

PACAUR_TEST_INPUT="$test_dir/no" check 1 'Package installation failed (exit status 1)' -U "$package" "$second_package"
assert_install "$package" "$second_package"
[[ $(< "$test_dir/stdout") == 'installation cancelled' ]] || fail 'cancellation claimed success'
for status in 1 4 42; do
    PACAUR_TEST_INSTALL_STATUS=$status check 1 "Package installation failed (exit status $status)" -U "$package"
    [[ $(< "$test_dir/stderr") == *'installation diagnostic'* ]] || fail 'lost original installation error'
    [[ $(< "$test_dir/stdout") == 'installation output' ]] || fail 'lost installation progress'
done
for status in 129 130 143; do
    PACAUR_TEST_INSTALL_STATUS=$status check "$status" "Package installation interrupted (exit status $status)" -U "$package"
done
if (( EUID != 0 )); then
    for status in 1 126 130; do
        expected=1
        (( status == 130 )) && expected=130
        PACAUR_TEST_SUDO_STATUS=$status check "$expected" "exit status $status" -U "$package"
        [[ ! -e $PACAUR_TEST_RECORD.install ]] || fail 'sudo failure still installed packages'
        [[ $(< "$test_dir/stderr") == *'mock sudo authentication error'* ]] || fail 'lost sudo error'
    done
else
    PATH="$test_dir/pacman-only" check 0 '' -U "$package"
    assert_install "$package"
fi
sha256sum --check --status "$test_dir/hashes" || fail 'changed package files or build logs'
printf 'Passed %d installation checks (uid %s).\n' "$checks" "$EUID"

if (( EUID == 0 )); then
    PATH="$original_path" runuser -u nobody -- "$bash_command" "$repository/tests/install.sh"
fi
