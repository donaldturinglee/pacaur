#!/usr/bin/env bash

repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
program="$repository/pacaur"
bash_command=$(command -v bash)
jq_command=$(command -v jq) || { printf 'Tests require jq.\n' >&2; exit 1; }
real_curl=$(command -v curl || true)
original_path=$PATH
test_parent=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
test_dir=$(mktemp -d "$test_parent/pacaur-cli-tests.XXXXXXXX")
checks=0

cleanup() {
    case "$test_dir" in
        "$test_parent"/pacaur-cli-tests.*) rm -rf -- "$test_dir" ;;
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

mkdir -p "$test_dir/bin" "$test_dir/curl-only" "$test_dir/jq-only" "$test_dir/empty"
export PACAUR_TEST_RESPONSE="$test_dir/response.json"
export PACAUR_TEST_REQUEST="$test_dir/request"
export PACAUR_TEST_DOWNLOAD_REQUEST="$test_dir/download-request"
cat > "$test_dir/bin/curl" <<'MOCK'
#!/bin/bash
arguments=("$@")
output=''
while (( $# )); do
    if [[ $1 == --output ]]; then
        output=$2
        shift 2
    else
        shift
    fi
done
if [[ -n $output ]]; then
    printf '%s\0' "${arguments[@]}" > "$PACAUR_TEST_DOWNLOAD_REQUEST"
    if [[ -n ${PACAUR_TEST_DOWNLOAD_SIGNAL:-} ]]; then
        printf 'partial snapshot' > "$output"
        kill -s "$PACAUR_TEST_DOWNLOAD_SIGNAL" "$PPID"
        exit 0
    fi
    if [[ ${PACAUR_TEST_DOWNLOAD_STATUS:-0} != 0 ]]; then
        printf 'partial snapshot' > "$output"
        exit "$PACAUR_TEST_DOWNLOAD_STATUS"
    fi
    cat -- "$PACAUR_TEST_ARCHIVE" > "$output" || exit 23
    if [[ -n ${PACAUR_TEST_COMPETING_TARGET:-} ]]; then
        printf 'concurrent file' > "$PACAUR_TEST_COMPETING_TARGET"
    fi
    exit 0
fi
printf '%s\0' "${arguments[@]}" > "$PACAUR_TEST_REQUEST"
if [[ ${PACAUR_TEST_CURL_STATUS:-0} != 0 ]]; then
    printf 'partial response'
    exit "$PACAUR_TEST_CURL_STATUS"
fi
cat -- "$PACAUR_TEST_RESPONSE"
MOCK
chmod +x "$test_dir/bin/curl"
ln -s "$test_dir/bin/curl" "$test_dir/curl-only/curl"
ln -s "$jq_command" "$test_dir/bin/jq"
ln -s "$jq_command" "$test_dir/jq-only/jq"
export PATH="$test_dir/bin:$original_path"

check() {
    local expected_status=$1 expected_error=$2 actual_status=0
    shift 2
    : > "$PACAUR_TEST_REQUEST"
    : > "$PACAUR_TEST_DOWNLOAD_REQUEST"
    "$bash_command" "$program" "$@" > "$test_dir/stdout" 2> "$test_dir/stderr" || actual_status=$?
    [[ $actual_status == "$expected_status" ]] || fail "expected status $expected_status, got $actual_status for $*"
    if (( expected_status == 0 )); then
        [[ ! -s "$test_dir/stderr" ]] || fail "unexpected stderr for $*"
    else
        [[ ! -s "$test_dir/stdout" ]] || fail "unexpected stdout for $*"
        [[ $(< "$test_dir/stderr") == *"$expected_error"* ]] || fail "missing error '$expected_error' for $*"
    fi
    ((checks += 1))
}

change_response() {
    "$jq_command" "$1" "$PACAUR_TEST_RESPONSE" > "$test_dir/changed.json"
    mv -- "$test_dir/changed.json" "$PACAUR_TEST_RESPONSE"
}
