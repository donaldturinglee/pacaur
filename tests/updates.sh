#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

export PACAUR_TEST_REAL_VERCMP
PACAUR_TEST_REAL_VERCMP=$(command -v vercmp) || fail 'Update tests require vercmp.'
export PACAUR_TEST_CAT
PACAUR_TEST_CAT=$(command -v cat)
export PACAUR_TEST_JQ="$jq_command"
export PACAUR_TEST_LOCAL="$test_dir/local"
export PACAUR_TEST_DIAGNOSTIC="$test_dir/local-stderr"
export PACAUR_TEST_CALLS="$test_dir/calls"
timeout_command=$(command -v timeout)
rm_command=$(command -v rm)
mkdir "$PACAUR_TEST_CALLS" "$test_dir/pacman-only"
: > "$PACAUR_TEST_DIAGNOSTIC"

cat > "$test_dir/bin/pacman" <<'MOCK'
#!/bin/bash
printf '%s\0' "$@" > "$PACAUR_TEST_CALLS/local.args"
[[ $# == 1 && $1 == -Qm ]] || exit 99
"$PACAUR_TEST_CAT" "$PACAUR_TEST_LOCAL"
"$PACAUR_TEST_CAT" "$PACAUR_TEST_DIAGNOSTIC" >&2
exit "${PACAUR_TEST_LOCAL_STATUS:-0}"
MOCK
cat > "$test_dir/bin/curl" <<'MOCK'
#!/bin/bash
count=0
[[ ! -e $PACAUR_TEST_CALLS/http-count ]] || read -r count < "$PACAUR_TEST_CALLS/http-count"
((count += 1))
printf '%s\n' "$count" > "$PACAUR_TEST_CALLS/http-count"
printf '%s\0' "$@" > "$PACAUR_TEST_CALLS/http-$count.args"
if [[ $count == "${PACAUR_TEST_FAIL_BATCH:-1}" && ${PACAUR_TEST_CURL_STATUS:-0} != 0 ]]; then
    printf 'partial response'
    exit "$PACAUR_TEST_CURL_STATUS"
fi
if [[ $count == "${PACAUR_TEST_BAD_BATCH:-0}" ]]; then
    printf '{bad json'
    exit 0
fi
names=()
while (( $# )); do
    if [[ $1 == --data-urlencode ]]; then
        [[ $2 != 'arg[]='* ]] || names+=("${2#arg[]=}")
        shift 2
    else
        shift
    fi
done
if [[ ${PACAUR_TEST_RAW_RESPONSE:-0} == 1 ]]; then
    exec "$PACAUR_TEST_CAT" "$PACAUR_TEST_RESPONSE"
fi
exec "$PACAUR_TEST_JQ" -c '
    $ARGS.positional as $names |
    .results |= map(select(.Name as $name | ($names | index($name)) != null)) |
    .resultcount = (.results | length)
' "$PACAUR_TEST_RESPONSE" --args "${names[@]}"
MOCK
cat > "$test_dir/bin/vercmp" <<'MOCK'
#!/bin/bash
count=0
[[ ! -e $PACAUR_TEST_CALLS/compare-count ]] || read -r count < "$PACAUR_TEST_CALLS/compare-count"
((count += 1))
printf '%s\n' "$count" > "$PACAUR_TEST_CALLS/compare-count"
printf '%s\0' "$@" >> "$PACAUR_TEST_CALLS/compare.args"
if [[ $count == "${PACAUR_TEST_FAIL_COMPARE:-1}" && ${PACAUR_TEST_COMPARE_STATUS:-0} != 0 ]]; then
    printf 'mock vercmp diagnostic\n' >&2
    exit "$PACAUR_TEST_COMPARE_STATUS"
fi
if [[ ${PACAUR_TEST_COMPARE_OUTPUT+present} ]]; then
    printf '%s\n' "$PACAUR_TEST_COMPARE_OUTPUT"
    exit 0
fi
exec "$PACAUR_TEST_REAL_VERCMP" "$@"
MOCK
for tool in sudo makepkg; do
    cat > "$test_dir/bin/$tool" <<'MOCK'
#!/bin/bash
: > "$PACAUR_TEST_CALLS/forbidden"
exit 99
MOCK
done
chmod +x "$test_dir/bin/"{pacman,curl,vercmp,sudo,makepkg}
ln -s "$test_dir/bin/pacman" "$test_dir/pacman-only/pacman"

check_updates() {
    local expected=$1 expected_error=$2 actual=0
    shift 2
    "$rm_command" -f -- "$PACAUR_TEST_CALLS/"*
    "$timeout_command" --kill-after=2 30 "$bash_command" "$program" "$@" \
        > "$test_dir/stdout" 2> "$test_dir/stderr" || actual=$?
    [[ $actual == "$expected" ]] || fail "expected $expected, got $actual for $*"
    if [[ -z $expected_error ]]; then
        [[ ! -s $test_dir/stderr ]] || fail 'unexpected diagnostic'
    else
        [[ $(< "$test_dir/stderr") == *"$expected_error"* ]] || fail "missing diagnostic: $expected_error"
    fi
    if (( expected != 0 )); then
        [[ ! -s $test_dir/stdout ]] || fail 'failure published incomplete results'
    fi
    [[ ! -e $PACAUR_TEST_CALLS/forbidden ]] || fail 'update check invoked sudo or makepkg'
    ((checks += 1))
}

no_requests() {
    [[ ! -e $PACAUR_TEST_CALLS/http-count && ! -e $PACAUR_TEST_CALLS/compare-count ]] \
        || fail 'invalid/empty local query reached AUR or version comparison'
}

write_fixture() {
    printf '%s\n' 'zeta 2.0-1' 'alpha 1.0-1' 'same 1.0-1' > "$PACAUR_TEST_LOCAL"
    "$jq_command" -cn '{version: 5, type: "multiinfo", resultcount: 3, results: [
        {Name: "same", Version: "1.0-1", PackageBase: "same"}, {Name: "zeta", Version: "3.0-1", PackageBase: "zeta"},
        {Name: "alpha", Version: "1.1-1", PackageBase: "alpha"}
    ]}' > "$PACAUR_TEST_RESPONSE"
    : > "$PACAUR_TEST_DIAGNOSTIC"
}

assert_batches() {
    local expected_names=$1 count index argument cost total=0
    local -a arguments names
    [[ -s $PACAUR_TEST_CALLS/http-count ]] || fail 'missing AUR requests'
    read -r count < "$PACAUR_TEST_CALLS/http-count"
    for ((index=1; index<=count; index++)); do
        mapfile -d '' -t arguments < "$PACAUR_TEST_CALLS/http-$index.args"
        [[ ${arguments[0]} == --disable && ${arguments[-1]} == 'https://aur.archlinux.org/rpc/' ]] \
            || fail 'unexpected curl configuration or origin'
        names=()
        for argument in "${arguments[@]}"; do
            [[ $argument != 'arg[]='* ]] || names+=("${argument#arg[]=}")
        done
        (( ${#names[@]} > 0 && ${#names[@]} <= 100 )) || fail 'invalid batch count'
        cost=$("$jq_command" -n '$ARGS.positional | map((@uri | length) + 16) | add' --args "${names[@]}")
        (( cost <= 3500 )) || fail 'encoded batch is too large'
        ((total += ${#names[@]}))
    done
    [[ $total == "$expected_names" ]] || fail 'candidate list was lost or duplicated across requests'
}

write_fixture
PATH="$test_dir/empty" check_updates 0 '' -h
[[ $(< "$test_dir/stdout") == *'--checkupdates'* ]] || fail 'help omits update checking'
for extra in '' example --syncdeps --checkupdates; do
    PATH="$test_dir/empty" check_updates 2 'accepts no additional arguments' --checkupdates "$extra"
    [[ ! -e $PACAUR_TEST_CALLS/local.args ]] || fail 'argument error queried pacman'
    no_requests
done
PATH="$test_dir/empty" check_updates 1 'Required command not found: pacman' --checkupdates
no_requests

: > "$PACAUR_TEST_LOCAL"
for status in 0 1; do
    PATH="$test_dir/pacman-only" PACAUR_TEST_LOCAL_STATUS=$status check_updates 0 '' --checkupdates
    [[ $(< "$test_dir/stdout") == 'No foreign packages installed.' ]] || fail 'missing no-candidate message'
    no_requests
done
for status in 1 2 127 130; do
    printf 'mock database/configuration error\n' > "$PACAUR_TEST_DIAGNOSTIC"
    PACAUR_TEST_LOCAL_STATUS=$status check_updates 1 "pacman exit status $status" --checkupdates
    [[ $(< "$test_dir/stderr") == *'mock database/configuration error'* ]] || fail 'lost pacman error'
    no_requests
done
: > "$PACAUR_TEST_DIAGNOSTIC"
PACAUR_TEST_LOCAL_STATUS=2 check_updates 1 'pacman exit status 2' --checkupdates
no_requests
write_fixture
PACAUR_TEST_LOCAL_STATUS=1 check_updates 1 'pacman exit status 1' --checkupdates
no_requests
for listing in 'example' 'example 1.0 extra' 'example -h' $'example 1.0\nexample 2.0' \
    $'example 1.0\n\nother 2.0' $'example\t1.0' $'example 1.0\033[2J' 'local/example 1.0'; do
    printf '%s\n' "$listing" > "$PACAUR_TEST_LOCAL"
    check_updates 1 'local package' --checkupdates
    no_requests
done

write_fixture
for missing_tool in curl jq vercmp; do
    dependency_dir="$test_dir/without-$missing_tool"
    mkdir "$dependency_dir"
    for tool in pacman curl jq vercmp; do
        [[ $tool == "$missing_tool" ]] || ln -s "$test_dir/bin/$tool" "$dependency_dir/$tool"
    done
    PATH="$dependency_dir" check_updates 1 "Required command not found: $missing_tool" --checkupdates
    no_requests
done

PATH="$test_dir/bin" check_updates 0 '' --checkupdates
[[ $(< "$test_dir/stdout") == $'alpha 1.0-1 -> 1.1-1\nzeta 2.0-1 -> 3.0-1' ]] \
    || fail 'updates are incomplete, incorrectly matched or unsorted'
assert_batches 3
mapfile -d '' -t local_arguments < "$PACAUR_TEST_CALLS/local.args"
[[ ${#local_arguments[@]} == 1 && ${local_arguments[0]} == -Qm ]] || fail 'local query was not read-only'
mapfile -d '' -t comparisons < "$PACAUR_TEST_CALLS/compare.args"
[[ ${comparisons[*]} == '1.0-1 1.1-1 1.0-1 1.0-1 2.0-1 3.0-1' ]] || fail 'wrong comparison operands'

# Real libalpm comparisons, including numeric ordering, epochs and package releases.
while IFS='|' read -r installed available newer; do
    printf 'example %s\n' "$installed" > "$PACAUR_TEST_LOCAL"
    "$jq_command" -cn --arg version "$available" '{version: 5, type: "multiinfo", resultcount: 1,
        results: [{Name: "example", Version: $version, PackageBase: "example"}]}' > "$PACAUR_TEST_RESPONSE"
    check_updates 0 '' --checkupdates
    if [[ $newer == yes ]]; then
        [[ $(< "$test_dir/stdout") == "example $installed -> $available" ]] || fail 'missed version update'
    else
        [[ $(< "$test_dir/stdout") == 'No newer AUR versions found for matched packages.' ]] \
            || fail 'equal/older AUR version was offered as an update'
    fi
done <<'VERSIONS'
2.0-1|10.0-1|yes
1.0-1|1.0-2|yes
1:9.0-1|2:1.0-1|yes
2:1.0-1|1:9.0-1|no
1.0rc1-1|1.0-1|yes
1.01-1|1.1-1|no
1.0-1|1.0-1|no
3.0-1|2.0-1|no
1.r123-1|1.r120-1|no
1.0+git_2-1|1.0+git_10-1|yes
VERSIONS

write_fixture
change_response '.results |= map(select(.Name != "same")) | .resultcount = (.results | length)'
check_updates 0 'Not found in AUR: same' --checkupdates
[[ $(< "$test_dir/stdout") == $'alpha 1.0-1 -> 1.1-1\nzeta 2.0-1 -> 3.0-1' ]] \
    || fail 'missing AUR candidate hid valid updates'
change_response '.results = [] | .resultcount = 0'
check_updates 0 'Not found in AUR: alpha' --checkupdates
[[ $(< "$test_dir/stdout") == 'No installed foreign packages were found in AUR.' ]] || fail 'missing all-unmatched message'
[[ $(< "$test_dir/stderr") == $'pacaur: Not found in AUR: alpha\npacaur: Not found in AUR: same\npacaur: Not found in AUR: zeta' ]] \
    || fail 'unmatched candidates are missing or unsorted'
[[ ! -e $PACAUR_TEST_CALLS/compare-count ]] || fail 'unmatched packages reached vercmp'

for mutation in \
    '.version = 4' \
    '.type = "search"' \
    '.results = {}' \
    '.resultcount = 0' \
    '.results[0] = null' \
    '.results[0].Name = null' \
    '.results[0].Name = "different-package"' \
    '.results += [.results[0]] | .resultcount = 4' \
    'del(.results[0].PackageBase)' \
    '.results[0].PackageBase = null' \
    '.results[0].PackageBase = 12' \
    '.results[0].PackageBase = ""' \
    '.results[0].PackageBase = "../outside"' \
    '.results[0].PackageBase = "base\tother"' \
    '.results[0].Version = null' \
    '.results[0].Version = ""' \
    '.results[0].Version = "-h"' \
    '.results[0].Version = "1 2"' \
    '.results[0].Version = "1\t2"' \
    '.results[0].Version = "1\n2"' \
    '.results[0].Version = "1\u001b[2J"'; do
    write_fixture
    change_response "$mutation"
    PACAUR_TEST_RAW_RESPONSE=1 check_updates 1 'AUR' --checkupdates
    [[ ! -e $PACAUR_TEST_CALLS/compare-count ]] || fail 'invalid response reached comparison'
done
for response in '<html>unavailable</html>' '' '[]' '{} {}'; do
    printf '%s' "$response" > "$PACAUR_TEST_RESPONSE"
    PACAUR_TEST_RAW_RESPONSE=1 check_updates 1 'invalid JSON response' --checkupdates
done
printf '%s\n' '{"version":5,"type":"error","error":"Service unavailable"}' > "$PACAUR_TEST_RESPONSE"
PACAUR_TEST_RAW_RESPONSE=1 check_updates 1 'AUR API error: Service unavailable' --checkupdates
write_fixture
for status in 6 22 28; do
    PACAUR_TEST_CURL_STATUS=$status check_updates 1 'AUR request' --checkupdates
done
for output in '' bad $'1\n-1'; do
    PACAUR_TEST_COMPARE_OUTPUT="$output" check_updates 1 'Unexpected vercmp output' --checkupdates
done
PACAUR_TEST_FAIL_COMPARE=2 PACAUR_TEST_COMPARE_STATUS=2 check_updates 1 'vercmp exit status 2' --checkupdates
[[ $(< "$test_dir/stderr") == *'mock vercmp diagnostic'* ]] || fail 'lost comparison error'

# Count-limited batches must retain every target and only publish complete results.
for ((index=0; index<101; index++)); do printf 'p%03d 1-1\n' "$index"; done > "$PACAUR_TEST_LOCAL"
"$jq_command" -Rn '[inputs | split(" ")[0] | {Name: ., Version: "2-1", PackageBase: .}] | reverse |
    {version: 5, type: "multiinfo", resultcount: length, results: .}' \
    "$PACAUR_TEST_LOCAL" > "$PACAUR_TEST_RESPONSE"
check_updates 0 '' --checkupdates
assert_batches 101
[[ $(< "$PACAUR_TEST_CALLS/http-count") == 2 ]] || fail '100-name batch limit not applied'
mapfile -t output_lines < "$test_dir/stdout"
[[ ${#output_lines[@]} == 101 && ${output_lines[0]} == 'p000 1-1 -> 2-1' \
    && ${output_lines[100]} == 'p100 1-1 -> 2-1' ]] || fail 'batched output was truncated or unsorted'
PACAUR_TEST_FAIL_BATCH=2 PACAUR_TEST_CURL_STATUS=28 check_updates 1 'request timed out' --checkupdates
[[ ! -e $PACAUR_TEST_CALLS/compare-count ]] || fail 'compared an incomplete batch set'
PACAUR_TEST_BAD_BATCH=2 check_updates 1 'invalid JSON response' --checkupdates

# Percent-encoded names can hit the URL limit before the package-count limit.
"$jq_command" -nr 'range(10) | "long" + tostring + ("+" * 160) + " 1-1"' > "$PACAUR_TEST_LOCAL"
"$jq_command" -Rn '[inputs | split(" ")[0] | {Name: ., Version: "2-1", PackageBase: .}] |
    {version: 5, type: "multiinfo", resultcount: length, results: .}' \
    "$PACAUR_TEST_LOCAL" > "$PACAUR_TEST_RESPONSE"
check_updates 0 '' --checkupdates
assert_batches 10
(( $(< "$PACAUR_TEST_CALLS/http-count") > 1 )) || fail 'encoded-length limit was ignored'
"$jq_command" -nr '"too-long" + ("a" * 3500) + " 1-1"' > "$PACAUR_TEST_LOCAL"
check_updates 1 'too long for an AUR update query' --checkupdates
no_requests

printf 'Passed %d update checks using real vercmp.\n' "$checks"
