#!/usr/bin/env bash
set -euo pipefail

repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
program="$repository/pacaur"
bash_command=$(command -v bash)
timeout_command=$(command -v timeout)
setsid_command=$(command -v setsid)
original_path=$PATH
test_parent=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
test_dir=$(mktemp -d "$test_parent/pacaur-build-tests.XXXXXXXX")
checks=0

cleanup() {
    case "$test_dir" in
        "$test_parent"/pacaur-build-tests.*)
            chmod -R u+rwX -- "$test_dir"
            rm -rf -- "$test_dir"
            ;;
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

mkdir -p "$test_dir/bin" "$test_dir/makepkg-only" "$test_dir/empty" "$test_dir/build directory"
build_dir="$test_dir/build directory"
export PACAUR_TEST_RECORD="$test_dir/record"
export PACAUR_TEST_CANARY="$test_dir/canary"
printf 'printf executed > "$PACAUR_TEST_CANARY"\n' > "$build_dir/PKGBUILD"
printf 'interactive input\n' > "$test_dir/stdin"
mkfifo "$test_dir/wait.fifo"
export PACAUR_TEST_FIFO="$test_dir/wait.fifo"

cat > "$test_dir/bin/makepkg" <<'MOCK'
#!/bin/bash
printf '%s\n' "$PWD" > "$PACAUR_TEST_RECORD.cwd"
printf '%s\0' "$@" > "$PACAUR_TEST_RECORD.args"
printf '%s\n' "$$" > "$PACAUR_TEST_RECORD.pid"
printf 'build output\n'
printf 'build diagnostic\n' >&2
printf 'build work\n' > build-work
printf 'build log\n' > "${LOGDEST:-$PWD}/fixture-build.log"
if [[ -n ${PACAUR_TEST_STDIN:-} ]]; then
    IFS= read -r input || exit 91
    printf '%s\n' "$input" > "$PACAUR_TEST_RECORD.stdin"
fi
if [[ -n ${PACAUR_TEST_SIGNAL:-} ]]; then
    "$BASH" -c 'exec 4<> "$PACAUR_TEST_FIFO"; while :; do read -r -t 5 -u 4 || true; done' &
    worker=$!
    printf '%s\n' "$worker" > "$PACAUR_TEST_RECORD.worker"
    trap 'wait "$worker" 2> /dev/null || true; printf terminated > "$PACAUR_TEST_RECORD.terminated"; exit 143' TERM
    exec 3<> "$PACAUR_TEST_FIFO"
    kill -s "$PACAUR_TEST_SIGNAL" "$PPID"
    while :; do read -r -t 5 -u 3 || true; done
fi
if [[ ${PACAUR_TEST_STATUS:-0} != 0 ]]; then
    exit "$PACAUR_TEST_STATUS"
fi
for package in ${PACAUR_TEST_PACKAGES:-fixture}; do
    target="${PKGDEST:-$PWD}/$package-1-1-any${PKGEXT:-.pkg.tar.zst}"
    [[ ! -e $target ]] || exit 13
    printf 'package %s\n' "$package" > "$target" || exit 11
done
MOCK
chmod +x "$test_dir/bin/makepkg"
ln -s "$setsid_command" "$test_dir/bin/setsid"
ln -s "$test_dir/bin/makepkg" "$test_dir/makepkg-only/makepkg"
export PATH="$test_dir/bin:$original_path"

check() {
    local expected_status=$1 expected_error=$2 actual_status=0
    shift 2
    "$timeout_command" --kill-after=2 10 "$bash_command" "$program" "$@" \
        < "$test_dir/stdin" > "$test_dir/stdout" 2> "$test_dir/stderr" || actual_status=$?
    [[ $actual_status == "$expected_status" ]] || fail "expected status $expected_status, got $actual_status for $*"
    if [[ -n $expected_error ]]; then
        [[ $(< "$test_dir/stderr") == *"$expected_error"* ]] || fail "missing error '$expected_error' for $*"
    fi
    ((checks += 1))
}

if (( EUID == 0 )); then
    check 1 'Cannot build packages as root' -m "$build_dir"
    [[ ! -e $PACAUR_TEST_RECORD.pid ]] || fail 'root rejection executed makepkg'
    printf 'Passed %d root build check.\n' "$checks"
    PATH="$original_path" runuser -u nobody -- "$bash_command" "$repository/tests/build.sh"
    exit 0
fi

# Argument and environment failures must occur before running makepkg.
check 0 '' -h
[[ $(< "$test_dir/stdout") == *'-m DIRECTORY'* ]] || fail 'help omits build command'
check 2 '-m requires exactly one build directory' -m
check 2 '-m requires exactly one build directory' -m ''
check 2 '-m requires exactly one build directory' -m -h
check 2 '-m requires exactly one build directory' -m "$build_dir" extra
check 1 'Build directory does not exist' -m "$test_dir/missing"
check 1 'Build directory does not exist' -m "$build_dir/PKGBUILD"
check 1 'readable PKGBUILD' -m "$test_dir/empty"
mkdir "$test_dir/empty/PKGBUILD"
check 1 'readable PKGBUILD' -m "$test_dir/empty"
chmod 000 "$build_dir/PKGBUILD"
check 1 'readable PKGBUILD' -m "$build_dir"
chmod 600 "$build_dir/PKGBUILD"
PATH="$test_dir/empty" check 1 'Required command not found: makepkg' -m "$build_dir"
PATH="$test_dir/makepkg-only" check 1 'Required command not found: setsid' -m "$build_dir"
[[ ! -e $PACAUR_TEST_RECORD.pid ]] || fail 'validation executed makepkg'

# The wrapper needs no query tools; preserve makepkg arguments, streams and stdin.
caller_directory=$PWD
PACAUR_TEST_STDIN=1 PATH="$test_dir/bin" check 0 '' -m "$build_dir"
[[ $PWD == "$caller_directory" ]] || fail 'changed caller directory'
[[ $(< "$PACAUR_TEST_RECORD.cwd") == "$build_dir" ]] || fail 'wrong working directory'
mapfile -d '' -t arguments < "$PACAUR_TEST_RECORD.args"
[[ ${#arguments[@]} == 1 && ${arguments[0]} == --log ]] || fail 'unexpected makepkg arguments'
[[ $(< "$test_dir/stdout") == 'build output' ]] || fail 'stdout not forwarded'
[[ $(< "$test_dir/stderr") == 'build diagnostic' ]] || fail 'stderr not forwarded'
[[ $(< "$PACAUR_TEST_RECORD.stdin") == 'interactive input' ]] || fail 'stdin not forwarded'
[[ ! -e $PACAUR_TEST_CANARY ]] || fail 'wrapper sourced PKGBUILD'
[[ -f $build_dir/fixture-1-1-any.pkg.tar.zst && -f $build_dir/fixture-build.log ]] || fail 'missing package or log'

printf 'existing package\n' > "$build_dir/fixture-1-1-any.pkg.tar.zst"
check 1 'makepkg failed (exit status 13)' -m "$build_dir"
[[ $(< "$build_dir/fixture-1-1-any.pkg.tar.zst") == 'existing package' ]] || fail 'overwrote existing package'
rm -- "$build_dir/fixture-1-1-any.pkg.tar.zst"

cd -- "$test_dir"
check 0 '' -m './build directory'
mkdir -- './-leading-dash'
cp -- "$build_dir/PKGBUILD" './-leading-dash/PKGBUILD'
check 0 '' -m './-leading-dash'
cd -- "$caller_directory"

# makepkg owns output locations, archive extensions and split-package behavior.
mkdir "$test_dir/package output" "$test_dir/build logs"
PKGDEST="$test_dir/package output" LOGDEST="$test_dir/build logs" PKGEXT=.pkg.tar.gz \
    PACAUR_TEST_PACKAGES='fixture fixture-doc' check 0 '' -m "$build_dir"
[[ -f $test_dir/package\ output/fixture-1-1-any.pkg.tar.gz \
    && -f $test_dir/package\ output/fixture-doc-1-1-any.pkg.tar.gz \
    && -f $test_dir/build\ logs/fixture-build.log ]] || fail 'did not preserve makepkg configuration'

# Preserve progress, work and logs on failures; expose the original status.
for status in 2 4 8 11 15; do
    PACAUR_TEST_STATUS=$status check 1 "makepkg failed (exit status $status)" -m "$build_dir"
    [[ $(< "$test_dir/stdout") == 'build output' ]] || fail 'failure lost stdout'
    [[ -f $build_dir/build-work && -f $build_dir/fixture-build.log ]] || fail 'failure removed work or logs'
done

# Cancel the wrapper while the child is active, and verify that child is reaped.
for signal in HUP INT TERM; do
    case $signal in
        HUP) status=129 ;;
        INT) status=130 ;;
        TERM) status=143 ;;
    esac
    rm -f -- "$PACAUR_TEST_RECORD.terminated"
    PACAUR_TEST_SIGNAL=$signal check "$status" "Build interrupted (exit status $status)" -m "$build_dir"
    [[ -f $PACAUR_TEST_RECORD.terminated ]] || fail "$signal did not reach makepkg"
    if kill -0 "$(< "$PACAUR_TEST_RECORD.pid")" 2> /dev/null; then
        fail "$signal left makepkg running"
    fi
    if kill -0 "$(< "$PACAUR_TEST_RECORD.worker")" 2> /dev/null; then
        fail "$signal left a build worker running"
    fi
    [[ -f $build_dir/build-work && -f $build_dir/fixture-build.log ]] || fail "$signal removed work or logs"
done

printf 'Passed %d non-root build checks.\n' "$checks"
