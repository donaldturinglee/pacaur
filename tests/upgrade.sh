#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

if (( EUID == 0 )); then
    check 1 'Cannot run -u as root' -u
    check 1 'Cannot run -u as root' -u --syncdeps
    [[ ! -s $PACAUR_TEST_REQUEST ]] || fail 'root upgrade contacted AUR'
    printf 'Passed %d root upgrade checks.\n' "$checks"
    PATH="$original_path" runuser -u nobody -- "$bash_command" "$repository/tests/upgrade.sh"
    exit 0
fi

timeout_command=$(command -v timeout)
script_command=$(command -v script)
rm_command=$(command -v rm)
export PACAUR_TEST_DB="$test_dir/db"
export PACAUR_TEST_EVENTS="$test_dir/events"
export PACAUR_TEST_RECORDS="$test_dir/records"
export PACAUR_TEST_CURRENT="$test_dir/current"
export PACAUR_TEST_JQ="$jq_command"
mkdir "$PACAUR_TEST_DB" "$PACAUR_TEST_RECORDS" "$test_dir/workspaces" "$test_dir/source"
mkdir "$test_dir/source/sample-base"
export TMPDIR="$test_dir/workspaces"
cat > "$test_dir/source/sample-base/PKGBUILD" <<'RECIPE'
pkgname=(alpha beta gamma)
pkgver=2
pkgrel=1
printf 'recipe\n' >> "$PACAUR_TEST_EVENTS"
RECIPE
export PACAUR_TEST_ARCHIVES="$test_dir/archives"
mkdir "$PACAUR_TEST_ARCHIVES"
for base in alpha beta gamma bundle; do
    mkdir "$test_dir/source/$base"
    cp "$test_dir/source/sample-base/PKGBUILD" "$test_dir/source/$base/PKGBUILD"
    tar -czf "$PACAUR_TEST_ARCHIVES/$base.tar.gz" -C "$test_dir/source" "$base"
done
"$jq_command" -cn '{version:5,type:"multiinfo",resultcount:3,results:
    ["alpha","beta","gamma"] | map({Name:.,Version:"2-1",PackageBase:.,
    URLPath:("/cgit/aur.git/snapshot/" + . + ".tar.gz")})}' > "$PACAUR_TEST_RESPONSE"
printf 'y\ny\ny\ny\ny\ny\ny\ny\ny\ny\n' > "$test_dir/yes"
printf 'n\n' > "$test_dir/no"
printf 'y\nn\n' > "$test_dir/review-no"
printf 'y\ny\nn\n' > "$test_dir/install-no"
printf 'y\ny\ny\nn\n' > "$test_dir/second-review-no"

cat > "$test_dir/bin/curl" <<'MOCK'
#!/bin/bash
names=()
output=''
while (( $# )); do
    case $1 in
        --output) output=$2; shift 2 ;;
        --data-urlencode)
            [[ $2 != 'arg[]='* ]] || names+=("${2#arg[]=}")
            shift 2
            ;;
        *) url=$1; shift ;;
    esac
done
if [[ -n $output ]]; then
    printf 'download\n' >> "$PACAUR_TEST_EVENTS"
    cat -- "$PACAUR_TEST_ARCHIVES/${url##*/}" > "$output"
    exit 0
fi
printf 'rpc\n' >> "$PACAUR_TEST_EVENTS"
count=0
[[ ! -e $PACAUR_TEST_RECORDS/rpc-count ]] || read -r count < "$PACAUR_TEST_RECORDS/rpc-count"
((count += 1))
printf '%s\n' "$count" > "$PACAUR_TEST_RECORDS/rpc-count"
[[ ${PACAUR_TEST_CURL_STATUS:-0} == 0 ]] || exit "$PACAUR_TEST_CURL_STATUS"
if (( ${#names[@]} == 1 )); then printf '%s\n' "${names[0]}" > "$PACAUR_TEST_CURRENT"; fi
exec "$PACAUR_TEST_JQ" -c --arg missing "${PACAUR_TEST_AUR_MISSING:-}" \
    --arg shared "${PACAUR_TEST_SHARED_BASE:-0}" --arg moved "${PACAUR_TEST_MOVED_BASE:-}" \
    --arg vanished "${PACAUR_TEST_RECHECK_MISSING:-}" --argjson count "$count" \
    --argjson move_after "${PACAUR_TEST_MOVE_AFTER:-1}" '
    $ARGS.positional as $names | .results |= map(select(.Name != $missing) |
    select(.Name as $name | ($names | index($name)) != null) |
    select($count <= 1 or .Name != $vanished) |
    (if $shared == "1" and (.Name == "alpha" or .Name == "beta") then .PackageBase = "bundle" else . end) |
    (if $count > $move_after and .Name == $moved then .PackageBase = "other-base" else . end) |
    .URLPath = ("/cgit/aur.git/snapshot/" + .PackageBase + ".tar.gz")) |
    .resultcount = (.results | length)
' "$PACAUR_TEST_RESPONSE" --args "${names[@]}"
MOCK
cat > "$test_dir/bin/pacman-conf" <<'MOCK'
#!/bin/bash
printf 'config:%s\n' "$1" >> "$PACAUR_TEST_EVENTS"
if [[ ${PACAUR_TEST_CONFIG_STATUS:-0} != 0 ]]; then
    printf 'mock config error\n' >&2
    exit "$PACAUR_TEST_CONFIG_STATUS"
fi
case $1 in
    IgnorePkg) [[ -z ${PACAUR_TEST_IGNORE_PKG:-} ]] || printf '%s\n' "$PACAUR_TEST_IGNORE_PKG" ;;
    IgnoreGroup) [[ -z ${PACAUR_TEST_IGNORE_GROUP:-} ]] || printf '%s\n' "$PACAUR_TEST_IGNORE_GROUP" ;;
    *) exit 99 ;;
esac
exit 0
MOCK
cat > "$test_dir/bin/makepkg" <<'MOCK'
#!/bin/bash
source ./PKGBUILD || exit 4
read -r target < "$PACAUR_TEST_CURRENT"
destination=$PWD
if [[ ${PACAUR_TEST_SPACED_OUTPUT:-0} == 1 ]]; then destination="$PWD/package output"; mkdir -p "$destination"; fi
case $1 in
    --log)
        printf 'build:%s\n' "$target" >> "$PACAUR_TEST_EVENTS"
        printf '%s\0' "$@" > "$PACAUR_TEST_RECORDS/$target.build"
        printf 'build log\n' > "$target.log"
        if [[ ${2:-} == --syncdeps && ${PACAUR_TEST_DEPS_REQUIRED:-0} == 1 ]]; then
            sudo -k pacman -S --asdeps fixture-dep || exit 8
        fi
        if [[ ${PACAUR_TEST_BUILD_FAIL:-} == "$target" ]]; then
            printf 'mock build error\n' >&2
            exit 4
        fi
        change_target=${PACAUR_TEST_CHANGE_TARGET:-$target}
        if [[ ${PACAUR_TEST_CHANGE_DURING_BUILD:-} == remove ]]; then
            rm -- "$PACAUR_TEST_DB/$change_target"
        elif [[ ${PACAUR_TEST_CHANGE_DURING_BUILD:-} == version ]]; then
            printf '3-1 explicit\n' > "$PACAUR_TEST_DB/$change_target"
        elif [[ ${PACAUR_TEST_CHANGE_DURING_BUILD:-} == reason ]]; then
            read -r old reason < "$PACAUR_TEST_DB/$change_target"
            if [[ $reason == explicit ]]; then reason=dependency; else reason=explicit; fi
            printf '%s %s\n' "$old" "$reason" > "$PACAUR_TEST_DB/$change_target"
        fi
        for name in alpha beta gamma; do
            [[ ${PACAUR_TEST_MISSING_OUTPUT:-} != "$name" ]] || continue
            version=${PACAUR_TEST_ARTIFACT_VERSION:-2-1}
            [[ $name != beta || -z ${PACAUR_TEST_BETA_ARTIFACT_VERSION:-} ]] || version=$PACAUR_TEST_BETA_ARTIFACT_VERSION
            printf '%s %s\n' "$name" "$version" > "$destination/$name.pkg"
        done
        printf 'unrequested-debug 2-1\n' > "$destination/debug.pkg"
        if [[ ${PACAUR_TEST_DUPLICATE_OUTPUT:-0} == 1 ]]; then cp "$destination/beta.pkg" "$destination/duplicate.pkg"; fi
        ;;
    --packagelist)
        [[ $# == 1 ]] || exit 98
        printf '%s\n' "$destination/alpha.pkg" "$destination/beta.pkg" "$destination/gamma.pkg" "$destination/debug.pkg"
        [[ ${PACAUR_TEST_DUPLICATE_OUTPUT:-0} != 1 ]] || printf '%s\n' "$destination/duplicate.pkg"
        ;;
    *) exit 97 ;;
esac
MOCK
cat > "$test_dir/bin/pacman" <<'MOCK'
#!/bin/bash
operation=$1
shift
case $operation in
    -Qm)
        printf 'local\n' >> "$PACAUR_TEST_EVENTS"
        if [[ ${PACAUR_TEST_LOCAL_STATUS:-0} != 0 ]]; then
            printf 'mock database error\n' >&2
            exit "$PACAUR_TEST_LOCAL_STATUS"
        fi
        shopt -s nullglob
        found=0
        for file in "$PACAUR_TEST_DB/"*; do
            read -r version reason < "$file"
            printf '%s %s\n' "${file##*/}" "$version"
            found=1
        done
        (( found )) || exit 1
        ;;
    -Qg)
        if [[ ${PACAUR_TEST_GROUP_STATUS:-0} != 0 ]]; then
            printf 'mock group query error\n' >&2
            exit "$PACAUR_TEST_GROUP_STATUS"
        fi
        [[ ${PACAUR_TEST_EMPTY_GROUPS:-0} == 1 ]] || printf 'protected-beta beta\n'
        ;;
    -Q|-Qeq|-Qdq)
        [[ $# == 2 && $1 == -- ]] || exit 96
        target=$2
        if [[ $operation == -Q && ${PACAUR_TEST_PRE_VERSION:-0} == 1 && ! -e $PACAUR_TEST_RECORDS/changed ]]; then
            : > "$PACAUR_TEST_RECORDS/changed"
            printf '3-1 explicit\n' > "$PACAUR_TEST_DB/$target"
        fi
        if [[ ! -f $PACAUR_TEST_DB/$target ]]; then printf 'mock target missing\n' >&2; exit 1; fi
        read -r version reason < "$PACAUR_TEST_DB/$target"
        case $operation in
            -Q) printf '%s %s\n' "$target" "$version" ;;
            -Qeq) [[ $reason == explicit ]] || exit 1; printf '%s\n' "$target" ;;
            -Qdq) [[ $reason == dependency ]] || exit 1; printf '%s\n' "$target" ;;
        esac
        ;;
    -Qp|-Qpq)
        [[ $1 == -- ]] || exit 95
        shift
        for file in "$@"; do
            read -r name version < "$file" || exit 1
            if [[ $operation == -Qpq ]]; then
                printf '%s\n' "$name"
            else
                printf '%s %s\n' "${PACAUR_TEST_METADATA_NAME:-$name}" "$version"
            fi
        done
        ;;
    -S)
        printf 'deps\n' >> "$PACAUR_TEST_EVENTS"
        printf 'Install dependencies? [y/N] ' >&2
        read -r answer || exit 1
        [[ $answer == y ]] || exit 1
        exit "${PACAUR_TEST_DEPS_STATUS:-0}"
        ;;
    -U)
        [[ $# -ge 2 && $1 == -- && ${PACAUR_TEST_PRIVILEGED:-0} == 1 ]] || exit 94
        arguments=("$@")
        shift
        names=() versions=()
        printf 'transaction\n' >> "$PACAUR_TEST_EVENTS"
        for file in "$@"; do
            read -r name version < "$file" || exit 1
            names+=("$name") versions+=("$version")
            printf '%s\0' -U "${arguments[@]}" > "$PACAUR_TEST_RECORDS/$name.install"
            printf 'install:%s\n' "$name" >> "$PACAUR_TEST_EVENTS"
            if [[ ${PACAUR_TEST_SIGNAL_TARGET:-} == "$name" ]]; then
                read -r group < <(ps -o pgid= -p "$$")
                kill -s "$PACAUR_TEST_GROUP_SIGNAL" -- "-$group"
                exit 99
            fi
            if [[ ${PACAUR_TEST_INSTALL_FAIL:-} == "$name" ]]; then
                printf 'mock dependency conflict\n' >&2
                exit 1
            fi
        done
        if [[ ${PACAUR_TEST_PINNED_SPLIT:-0} == 1 && " ${names[*]} " == *' alpha '* ]]; then
            [[ " ${names[*]} " == *' beta '* ]] || { printf 'beta=2-1 must be upgraded together\n' >&2; exit 1; }
        fi
        printf 'Install %s? [y/N] ' "${names[*]}" >&2
        read -r answer || exit 1
        [[ $answer == y ]] || exit 1
        for index in "${!names[@]}"; do
            name=${names[index]}
            [[ ${PACAUR_TEST_INSTALL_NOOP:-} != "$name" ]] || continue
            read -r old reason < "$PACAUR_TEST_DB/$name"
            [[ ${PACAUR_TEST_REASON_LOST:-} != "$name" ]] || reason=explicit
            printf '%s %s\n' "${versions[index]}" "$reason" > "$PACAUR_TEST_DB/$name"
        done
        ;;
    *) printf 'unexpected pacman operation: %s\n' "$operation" >&2; exit 93 ;;
esac
MOCK
cat > "$test_dir/bin/sudo" <<'MOCK'
#!/bin/bash
printf 'sudo\n' >> "$PACAUR_TEST_EVENTS"
if [[ ${PACAUR_TEST_AUTH_STATUS:-0} != 0 ]]; then
    printf 'mock authentication error\n' >&2
    exit "$PACAUR_TEST_AUTH_STATUS"
fi
[[ ( $1 == -- || $1 == -k ) && $2 == pacman ]] || exit 92
shift
export PACAUR_TEST_PRIVILEGED=1
exec "$@"
MOCK
chmod +x "$test_dir/bin/"{curl,pacman-conf,makepkg,pacman,sudo}

check_upgrade() {
    local expected=$1 error_text=$2 actual=0 terminal_command output
    shift 2
    "$rm_command" -f -- "$PACAUR_TEST_DB/"* "$PACAUR_TEST_RECORDS/"* "$PACAUR_TEST_EVENTS" "$PACAUR_TEST_CURRENT"
    if [[ ${PACAUR_TEST_EMPTY_DB:-0} != 1 ]]; then
        printf '%s explicit\n' "${PACAUR_TEST_INSTALLED_VERSION:-1-1}" > "$PACAUR_TEST_DB/alpha"
        printf '%s dependency\n' "${PACAUR_TEST_BETA_INSTALLED_VERSION:-${PACAUR_TEST_INSTALLED_VERSION:-1-1}}" > "$PACAUR_TEST_DB/beta"
        printf '%s explicit\n' "${PACAUR_TEST_INSTALLED_VERSION:-1-1}" > "$PACAUR_TEST_DB/gamma"
        [[ ${PACAUR_TEST_NO_BETA:-0} != 1 ]] || "$rm_command" -f -- "$PACAUR_TEST_DB/beta"
    fi
    if [[ ${PACAUR_TEST_TERMINAL:-0} == 1 ]]; then
        printf -v terminal_command '%q ' "$bash_command" "$program" "$@"
        "$timeout_command" --kill-after=2 30 "$script_command" --quiet --return --echo never \
            --command "exec $terminal_command" /dev/null < "${PACAUR_TEST_INPUT:-$test_dir/yes}" \
            > "$test_dir/stdout" 2> "$test_dir/stderr" || actual=$?
        output=$(< "$test_dir/stdout")
        printf '%s\n' "${output//$'\r'/}" > "$test_dir/stdout"
    else
        "$timeout_command" --kill-after=2 30 "$bash_command" "$program" "$@" \
            < "${PACAUR_TEST_INPUT:-$test_dir/yes}" > "$test_dir/stdout" 2> "$test_dir/stderr" || actual=$?
    fi
    [[ $actual == "$expected" ]] || fail "expected status $expected, got $actual for $*"
    [[ $(< "$test_dir/stdout") == *"$error_text"* || $(< "$test_dir/stderr") == *"$error_text"* ]] \
        || fail "missing diagnostic: $error_text"
    ((checks += 1))
}

no_build() {
    [[ ! -e $PACAUR_TEST_EVENTS || $(< "$PACAUR_TEST_EVENTS") != *'recipe'* ]] || fail 'failure/cancellation reached a build'
    [[ ! -e $PACAUR_TEST_EVENTS || $(< "$PACAUR_TEST_EVENTS") != *'sudo'* ]] || fail 'failure/cancellation requested elevation'
}

assert_group_summary() {
    local done=$1 stopped=$2 pending=$3 output
    output=$(< "$test_dir/stdout")
    [[ $output == *"Completed: $done"* && $output == *"Not processed: $pending"* ]] || fail 'incorrect progress summary'
    [[ -z $stopped || $output == *"Stopped at: $stopped (check member states)"* ]] || fail 'lost stopped target'
}

singleton_labels() {
    local text=$1 name output=''
    local -a names=()
    if [[ -z $text || $text == '(none)' ]]; then printf '%s' "$text"; return; fi
    read -r -a names <<< "$text"
    for name in "${names[@]}"; do output+="$name [$name] "; done
    printf '%s' "${output% }"
}

assert_summary() {
    assert_group_summary "$(singleton_labels "$1")" "$(singleton_labels "$2")" "$(singleton_labels "$3")"
}

check_upgrade 0 '' -h
[[ $(< "$test_dir/stdout") == *'-u [--syncdeps]'* ]] || fail 'help omits upgrades'
for extra in '' alpha --unknown; do
    PATH="$test_dir/empty" check_upgrade 2 'one optional --syncdeps' -u "$extra"
    [[ ! -e $PACAUR_TEST_EVENTS ]] || fail 'invalid arguments started a query'
done
check_upgrade 2 'one optional --syncdeps' -u --syncdeps --syncdeps
check_upgrade 2 'one optional --syncdeps' -u --syncdeps alpha
PACAUR_TEST_EMPTY_DB=1 check_upgrade 0 'No AUR upgrades available.' -u
no_build
PACAUR_TEST_INSTALLED_VERSION=2-1 check_upgrade 0 'No AUR upgrades available.' -u
no_build
PACAUR_TEST_LOCAL_STATUS=1 check_upgrade 1 'Foreign package query failed' -u
no_build
PACAUR_TEST_CURL_STATUS=28 check_upgrade 1 'request timed out' -u
no_build
PACAUR_TEST_CONFIG_STATUS=1 check_upgrade 1 'Unable to read pacman ignore rules' -u
no_build
PACAUR_TEST_IGNORE_GROUP='protected-*' PACAUR_TEST_GROUP_STATUS=1 check_upgrade 1 'Unable to query installed groups' -u
no_build

PACAUR_TEST_IGNORE_PKG='*' check_upgrade 0 'No AUR upgrades remain' -u
no_build
PACAUR_TEST_IGNORE_PKG=$'a*\ng?mma' PACAUR_TEST_IGNORE_GROUP='protected-*' check_upgrade 0 'No AUR upgrades remain' -u
no_build
PACAUR_TEST_IGNORE_PKG='a*' PACAUR_TEST_IGNORE_GROUP='protected-*' check_upgrade 0 '' -u
[[ $(< "$PACAUR_TEST_DB/alpha") == '1-1 explicit' && $(< "$PACAUR_TEST_DB/beta") == '1-1 dependency' \
    && $(< "$PACAUR_TEST_DB/gamma") == '2-1 explicit' ]] || fail 'ignore rules did not select the correct targets'
assert_summary gamma '' '(none)'
PACAUR_TEST_IGNORE_GROUP='protected-*' PACAUR_TEST_EMPTY_GROUPS=1 check_upgrade 0 '' -u
assert_summary 'alpha beta gamma' '' '(none)'

PACAUR_TEST_INPUT="$test_dir/no" check_upgrade 1 'Upgrade cancelled' -u
no_build
assert_summary '(none)' '' 'alpha beta gamma'
PACAUR_TEST_INPUT=/dev/null check_upgrade 1 'Upgrade cancelled' -u
no_build
PACAUR_TEST_INPUT="$test_dir/review-no" check_upgrade 1 'Build cancelled' -u
no_build
assert_summary '(none)' alpha 'beta gamma'
PACAUR_TEST_INPUT="$test_dir/install-no" check_upgrade 1 'Package installation failed' -u
assert_summary '(none)' alpha 'beta gamma'
[[ $(< "$PACAUR_TEST_DB/alpha") == '1-1 explicit' ]] || fail 'cancelled installation changed a target'

check_upgrade 0 '' -u
assert_summary 'alpha beta gamma' '' '(none)'
[[ $(< "$PACAUR_TEST_DB/beta") == '2-1 dependency' ]] || fail 'lost dependency installation reason'
for name in alpha beta gamma; do
    mapfile -d '' -t arguments < "$PACAUR_TEST_RECORDS/$name.install"
    [[ ${#arguments[@]} == 3 && ${arguments[0]} == -U && ${arguments[1]} == -- ]] || fail 'changed pacman transaction flags'
    mapfile -d '' -t arguments < "$PACAUR_TEST_RECORDS/$name.build"
    [[ ${#arguments[@]} == 1 && ${arguments[0]} == --log ]] || fail 'default upgrade changed build options'
done
PACAUR_TEST_DEPS_REQUIRED=1 check_upgrade 0 '' -u --syncdeps
assert_summary 'alpha beta gamma' '' '(none)'
for name in alpha beta gamma; do
    mapfile -d '' -t arguments < "$PACAUR_TEST_RECORDS/$name.build"
    [[ ${arguments[*]} == '--log --syncdeps' ]] || fail 'lost syncdeps option'
done
PACAUR_TEST_DEPS_REQUIRED=1 PACAUR_TEST_DEPS_STATUS=1 check_upgrade 1 'makepkg failed' -u --syncdeps
assert_summary '(none)' alpha 'beta gamma'
PACAUR_TEST_AUR_MISSING=beta check_upgrade 0 'Not found in AUR: beta' -u
assert_summary 'alpha gamma' '' '(none)'

PACAUR_TEST_BUILD_FAIL=beta check_upgrade 1 'makepkg failed' -u
assert_summary alpha beta gamma
[[ $(< "$PACAUR_TEST_DB/alpha") == '2-1 explicit' && $(< "$PACAUR_TEST_DB/beta") == '1-1 dependency' ]] \
    || fail 'partial build failure lost completed upgrades or changed the failing target'
[[ $(< "$PACAUR_TEST_EVENTS") != *'build:gamma'* ]] || fail 'continued after a build failure'
PACAUR_TEST_INPUT="$test_dir/second-review-no" check_upgrade 1 'Build cancelled' -u
assert_summary alpha beta gamma
PACAUR_TEST_INSTALL_FAIL=beta check_upgrade 1 'mock dependency conflict' -u
assert_summary alpha beta gamma
PACAUR_TEST_AUTH_STATUS=1 check_upgrade 1 'mock authentication error' -u
assert_summary '(none)' alpha 'beta gamma'
PACAUR_TEST_PRE_VERSION=1 check_upgrade 1 'Installed version changed' -u
no_build
assert_summary '(none)' alpha 'beta gamma'
for change in remove version reason; do
    PACAUR_TEST_CHANGE_DURING_BUILD=$change check_upgrade 1 '' -u
    [[ ! -e $PACAUR_TEST_RECORDS/alpha.install ]] || fail 'changed installed state reached installation'
    assert_summary '(none)' alpha 'beta gamma'
done
for version in 1-1 0-1; do
    PACAUR_TEST_ARTIFACT_VERSION=$version check_upgrade 1 'not newer than the installed version' -u
    [[ ! -e $PACAUR_TEST_RECORDS/alpha.install ]] || fail 'reinstalled or downgraded a target'
done
PACAUR_TEST_METADATA_NAME=other check_upgrade 1 'metadata does not match' -u
[[ ! -e $PACAUR_TEST_RECORDS/alpha.install ]] || fail 'mismatched artifact reached installation'
PACAUR_TEST_INSTALL_NOOP=alpha check_upgrade 1 'Upgrade could not be verified' -u
assert_summary '(none)' alpha 'beta gamma'
PACAUR_TEST_REASON_LOST=beta check_upgrade 1 'Upgrade could not be verified' -u
assert_summary alpha beta gamma
PACAUR_TEST_ARTIFACT_VERSION=3-1 check_upgrade 0 '' -u
[[ $(< "$PACAUR_TEST_DB/beta") == '3-1 dependency' ]] || fail 'valid newer artifact was not accepted'

for signal in HUP INT TERM; do
    case $signal in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    PACAUR_TEST_TERMINAL=1 PACAUR_TEST_SIGNAL_TARGET=beta PACAUR_TEST_GROUP_SIGNAL=$signal \
        check_upgrade "$expected" '' -u
    assert_summary alpha beta gamma
    [[ $(< "$PACAUR_TEST_DB/gamma") == '1-1 explicit' ]] || fail 'terminal interruption continued the batch'
done
assert_event_count() {
    local event=$1 expected=$2 line count=0
    if [[ -e $PACAUR_TEST_EVENTS ]]; then
        while IFS= read -r line; do
            [[ $line != "$event" ]] || ((count += 1))
        done < "$PACAUR_TEST_EVENTS"
    fi
    [[ $count == "$expected" ]] || fail "expected $expected '$event' events, got $count"
}

PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_PINNED_SPLIT=1 check_upgrade 0 '' -u
assert_group_summary 'bundle [alpha beta] gamma [gamma]' '' '(none)'
assert_event_count build:alpha 1
assert_event_count build:beta 0
assert_event_count download 2
assert_event_count transaction 2
mapfile -d '' -t arguments < "$PACAUR_TEST_RECORDS/alpha.install"
[[ ${#arguments[@]} == 4 && ${arguments[0]} == -U && ${arguments[1]} == -- \
    && ${arguments[2]} == */alpha.pkg && ${arguments[3]} == */beta.pkg ]] || fail 'split members were not installed together'
[[ $(< "$PACAUR_TEST_DB/alpha") == '2-1 explicit' && $(< "$PACAUR_TEST_DB/beta") == '2-1 dependency' ]] \
    || fail 'group upgrade lost versions or mixed installation reasons'
[[ ! -e $PACAUR_TEST_RECORDS/unrequested-debug.install ]] || fail 'installed an unrequested debug package'

PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_IGNORE_PKG=beta check_upgrade 0 'Skipped package base: bundle [alpha beta]' -u
assert_summary gamma '' '(none)'
assert_event_count build:alpha 0
[[ $(< "$PACAUR_TEST_DB/alpha") == '1-1 explicit' && $(< "$PACAUR_TEST_DB/beta") == '1-1 dependency' ]] \
    || fail 'partially upgraded an ignored base'
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_IGNORE_GROUP='protected-*' check_upgrade 0 'IgnoreGroup: protected-beta' -u
assert_summary gamma '' '(none)'
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_IGNORE_PKG=$'beta\ngamma' check_upgrade 0 'No AUR upgrades remain' -u
no_build
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_BETA_INSTALLED_VERSION=2-1 PACAUR_TEST_IGNORE_PKG=beta check_upgrade 0 '' -u
assert_group_summary 'bundle [alpha] gamma [gamma]' '' '(none)'
[[ ! -e $PACAUR_TEST_RECORDS/beta.install ]] || fail 'included an already-current sibling'
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_NO_BETA=1 check_upgrade 0 '' -u
assert_group_summary 'bundle [alpha] gamma [gamma]' '' '(none)'
[[ ! -e $PACAUR_TEST_DB/beta ]] || fail 'installed an uninstalled sibling'

PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_MOVED_BASE=beta check_upgrade 1 'Package base changed for beta' -u
no_build
assert_event_count download 0
assert_group_summary '(none)' 'bundle [alpha beta]' 'gamma [gamma]'
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_MOVED_BASE=alpha PACAUR_TEST_MOVE_AFTER=2 check_upgrade 1 'Package base changed for alpha' -u
no_build
assert_event_count download 0
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_RECHECK_MISSING=beta check_upgrade 1 'AUR update target disappeared: beta' -u
no_build
assert_event_count download 0

PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_MISSING_OUTPUT=beta check_upgrade 1 'Listed package must be a readable file' -u
assert_event_count transaction 0
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_DUPLICATE_OUTPUT=1 check_upgrade 1 'Multiple built packages match the target: beta' -u
assert_event_count transaction 0
for version in 1-1 0-1; do
    PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_BETA_ARTIFACT_VERSION=$version check_upgrade 1 'not newer than the installed version: beta' -u
    assert_event_count transaction 0
    [[ $(< "$PACAUR_TEST_DB/alpha") == '1-1 explicit' ]] || fail 'installed first member before checking all versions'
done
for change in remove version reason; do
    PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_CHANGE_TARGET=beta PACAUR_TEST_CHANGE_DURING_BUILD=$change check_upgrade 1 '' -u
    assert_event_count transaction 0
    assert_group_summary '(none)' 'bundle [alpha beta]' 'gamma [gamma]'
done
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_INSTALL_FAIL=beta check_upgrade 1 'mock dependency conflict' -u
assert_group_summary '(none)' 'bundle [alpha beta]' 'gamma [gamma]'
[[ $(< "$PACAUR_TEST_DB/alpha") == '1-1 explicit' && $(< "$PACAUR_TEST_DB/beta") == '1-1 dependency' ]] \
    || fail 'failed dependency preparation partially installed a group'
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_INSTALL_NOOP=beta check_upgrade 1 'Upgrade could not be verified for beta' -u
assert_group_summary '(none)' 'bundle [alpha beta]' 'gamma [gamma]'
[[ $(< "$PACAUR_TEST_DB/alpha") == '2-1 explicit' && $(< "$PACAUR_TEST_DB/beta") == '1-1 dependency' ]] \
    || fail 'test did not exercise a partially applied result'
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_REASON_LOST=beta check_upgrade 1 'Upgrade could not be verified for beta' -u
assert_group_summary '(none)' 'bundle [alpha beta]' 'gamma [gamma]'
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_INPUT="$test_dir/review-no" check_upgrade 1 'Build cancelled' -u
no_build
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_INPUT="$test_dir/install-no" check_upgrade 1 'Package installation failed' -u
assert_group_summary '(none)' 'bundle [alpha beta]' 'gamma [gamma]'
[[ $(< "$PACAUR_TEST_DB/alpha") == '1-1 explicit' && $(< "$PACAUR_TEST_DB/beta") == '1-1 dependency' ]] \
    || fail 'group cancellation changed packages'
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_DEPS_REQUIRED=1 check_upgrade 0 '' -u --syncdeps
assert_event_count deps 2
assert_event_count build:beta 0
PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_SPACED_OUTPUT=1 check_upgrade 0 '' -u
mapfile -d '' -t arguments < "$PACAUR_TEST_RECORDS/alpha.install"
[[ ${#arguments[@]} == 4 && ${arguments[2]} == *'/package output/alpha.pkg' \
    && ${arguments[3]} == *'/package output/beta.pkg' ]] || fail 'grouped paths containing spaces were split'
for signal in HUP INT TERM; do
    case $signal in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    PACAUR_TEST_SHARED_BASE=1 PACAUR_TEST_TERMINAL=1 PACAUR_TEST_SIGNAL_TARGET=beta PACAUR_TEST_GROUP_SIGNAL=$signal \
        check_upgrade "$expected" '' -u
    assert_group_summary '(none)' 'bundle [alpha beta]' 'gamma [gamma]'
    [[ $(< "$PACAUR_TEST_DB/gamma") == '1-1 explicit' ]] || fail 'group interruption continued the batch'
done
printf 'Passed %d non-root upgrade checks.\n' "$checks"
