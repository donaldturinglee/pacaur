#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

if (( EUID == 0 )); then
    check 1 'Cannot run -S as root' -S split-tool
    check 1 'Cannot run -S as root' -S split-tool --syncdeps
    [[ ! -s $PACAUR_TEST_REQUEST ]] || fail 'root rejection contacted AUR'
    printf 'Passed %d root workflow checks.\n' "$checks"
    PATH="$original_path" runuser -u nobody -- "$bash_command" "$repository/tests/sync.sh"
    exit 0
fi

rm_command=$(command -v rm)
timeout_command=$(command -v timeout)
script_command=$(command -v script)
cleanup() {
    case "$test_dir" in
        "$test_parent"/pacaur-cli-tests.*)
            chmod -R u+rwX -- "$test_dir"
            rm -rf -- "$test_dir"
            ;;
        *) printf 'Unexpected test directory: %s\n' "$test_dir" >&2; return 1 ;;
    esac
}
mkdir "$test_dir/workspaces" "$test_dir/source" "$test_dir/source/sample-base"
export TMPDIR="$test_dir/workspaces"
export PACAUR_TEST_EXECUTED="$test_dir/recipe-executed"
export PACAUR_TEST_PHASES="$test_dir/phases"
export PACAUR_TEST_INSTALL="$test_dir/install-arguments"
export PACAUR_TEST_SUDO="$test_dir/sudo-arguments"
export PACAUR_TEST_MAKEPKG_ARGS="$test_dir/makepkg-arguments"
export PACAUR_TEST_LIST_ARGS="$test_dir/list-arguments"
export PACAUR_TEST_DEPS_SUDO="$test_dir/dependency-sudo"
export PACAUR_TEST_DEPS_INSTALL="$test_dir/dependency-install"
export PACAUR_TEST_DEPS_PID="$test_dir/dependency-pid"
cat > "$test_dir/source/sample-base/PKGBUILD" <<'RECIPE'
pkgname=('split-tool' 'other-package')
pkgver=1
pkgrel=1
printf 'recipe executed\n' >> "$PACAUR_TEST_EXECUTED"
RECIPE
printf 'pkgbase = sample-base\n' > "$test_dir/source/sample-base/.SRCINFO"
mkdir "$test_dir/source/sample-base/sub dir"
printf '\033[2Jauxiliary file\n' > "$test_dir/source/sample-base/sub dir/file name.patch"
tar -czf "$test_dir/valid.tar.gz" -C "$test_dir/source" sample-base
export PACAUR_TEST_ARCHIVE="$test_dir/valid.tar.gz"
"$jq_command" -cn '{version: 5, type: "multiinfo", resultcount: 1, results: [{
    Name: "split-tool", PackageBase: "sample-base", URLPath: "/cgit/aur.git/snapshot/sample-base.tar.gz"
}]}' > "$PACAUR_TEST_RESPONSE"
printf 'y\ny\n' > "$test_dir/yes"
printf 'n\n' > "$test_dir/no"
printf '\n' > "$test_dir/blank"
printf 'y\nn\n' > "$test_dir/install-no"
printf 'y\ny\ny\n' > "$test_dir/deps-yes"
printf 'y\nn\n' > "$test_dir/deps-no"
printf 'y\nfixture-answer\ny\ny\n' > "$test_dir/terminal-yes"

cat > "$test_dir/bin/makepkg" <<'MOCK'
#!/bin/bash
source ./PKGBUILD || exit 4
destination=${PKGDEST:-$PWD}
extension=${PKGEXT:-.pkg.tar.zst}
case $1 in
    --log)
        printf '%s\0' "$@" > "$PACAUR_TEST_MAKEPKG_ARGS"
        if [[ ${2:-} == --syncdeps ]]; then
            [[ $# == 2 ]] || exit 99
            printf 'deps-check\n' >> "$PACAUR_TEST_PHASES"
        fi
        if [[ ${PACAUR_TEST_MISSING_DEPS:-0} == 1 ]]; then
            if [[ ${2:-} != --syncdeps ]]; then
                printf 'missing dependency: fixture-dep>=1\n' >&2
                exit 8
            fi
            sudo -k pacman -S --asdeps 'fixture-dep>=1' || exit 8
        fi
        printf 'build\n' >> "$PACAUR_TEST_PHASES"
        printf 'build progress\n'
        printf 'build work\n' > build-work
        printf 'build log\n' > "${LOGDEST:-$PWD}/fixture-build.log"
        [[ ${PACAUR_TEST_BUILD_STATUS:-0} == 0 ]] || exit "$PACAUR_TEST_BUILD_STATUS"
        printf 'other-package\n' > "$destination/other-1-1-any$extension"
        if [[ ${PACAUR_TEST_MISSING_OUTPUT:-0} != 1 ]]; then
            printf '%s\n' "${PACAUR_TEST_OUTPUT_NAME:-split-tool}" > "$destination/target-1-1-any$extension"
        fi
        if [[ ${PACAUR_TEST_DUPLICATE_OUTPUT:-0} == 1 ]]; then
            printf 'split-tool\n' > "$destination/duplicate-1-1-any$extension"
        fi
        ;;
    --packagelist)
        printf '%s\0' "$@" > "$PACAUR_TEST_LIST_ARGS"
        printf 'list\n' >> "$PACAUR_TEST_PHASES"
        [[ ${PACAUR_TEST_LIST_STATUS:-0} == 0 ]] || exit "$PACAUR_TEST_LIST_STATUS"
        [[ ${PACAUR_TEST_EMPTY_LIST:-0} != 1 ]] || exit 0
        printf '%s\n' "$destination/other-1-1-any$extension" "$destination/target-1-1-any$extension"
        if [[ ${PACAUR_TEST_DUPLICATE_OUTPUT:-0} == 1 ]]; then
            printf '%s\n' "$destination/duplicate-1-1-any$extension"
        fi
        ;;
    *) exit 99 ;;
esac
MOCK
cat > "$test_dir/bin/pacman" <<'MOCK'
#!/bin/bash
case $1 in
    -S)
        printf 'deps-install\n' >> "$PACAUR_TEST_PHASES"
        printf '%s\0' "$@" > "$PACAUR_TEST_DEPS_INSTALL"
        printf '%s\n' "$$" > "$PACAUR_TEST_DEPS_PID"
        if [[ -n ${PACAUR_TEST_DEPS_GROUP_SIGNAL:-} ]]; then
            read -r group < <(ps -o pgid= -p "$$")
            kill -s "$PACAUR_TEST_DEPS_GROUP_SIGNAL" -- "-$group"
            exit 99
        fi
        if [[ ${PACAUR_TEST_DEPS_STATUS:-0} != 0 ]]; then
            printf 'repository dependency unavailable\n' >&2
            exit "$PACAUR_TEST_DEPS_STATUS"
        fi
        printf 'Install repository dependencies? [y/N] ' >&2
        IFS= read -r answer || exit 1
        [[ $answer == y ]] || exit 1
        ;;
    -Qpq)
        printf 'identify\n' >> "$PACAUR_TEST_PHASES"
        [[ ${PACAUR_TEST_IDENTIFY_STATUS:-0} == 0 ]] || exit "$PACAUR_TEST_IDENTIFY_STATUS"
        [[ $2 == -- && $# == 3 ]] || exit 98
        IFS= read -r name < "$3" || exit 1
        printf '%s\n' "$name"
        ;;
    -Qp)
        printf 'validate\n' >> "$PACAUR_TEST_PHASES"
        exit "${PACAUR_TEST_VALIDATE_STATUS:-0}"
        ;;
    -U)
        printf 'install\n' >> "$PACAUR_TEST_PHASES"
        printf '%s\0' "$@" > "$PACAUR_TEST_INSTALL"
        printf 'Install? [y/N] ' >&2
        IFS= read -r answer || exit 1
        [[ $answer == y ]] || exit 1
        exit "${PACAUR_TEST_INSTALL_STATUS:-0}"
        ;;
    *) exit 97 ;;
esac
MOCK
cat > "$test_dir/bin/sudo" <<'MOCK'
#!/bin/bash
if [[ $1 == -k ]]; then
    printf 'deps-sudo\n' >> "$PACAUR_TEST_PHASES"
    printf '%s\0' "$@" > "$PACAUR_TEST_DEPS_SUDO"
    if [[ ${PACAUR_TEST_AUTH_TTY:-0} == 1 ]]; then
        exec 3<> /dev/tty || exit 1
        printf 'Test authentication answer: ' >&3
        IFS= read -rs answer <&3 || exit 1
        printf '\n' >&3
        [[ $answer == fixture-answer ]] || exit 1
        printf 'tty-auth\n' >> "$PACAUR_TEST_PHASES"
    fi
    [[ ${PACAUR_TEST_DEPS_AUTH_STATUS:-0} == 0 ]] || exit "$PACAUR_TEST_DEPS_AUTH_STATUS"
    shift
    exec "$@"
fi
printf 'sudo\n' >> "$PACAUR_TEST_PHASES"
printf '%s\0' "$@" > "$PACAUR_TEST_SUDO"
[[ ${PACAUR_TEST_SUDO_STATUS:-0} == 0 ]] || exit "$PACAUR_TEST_SUDO_STATUS"
[[ $1 == -- && $2 == pacman ]] || exit 96
shift
exec "$@"
MOCK
chmod +x "$test_dir/bin/makepkg" "$test_dir/bin/pacman" "$test_dir/bin/sudo"

check_sync() {
    local expected=$1 error_text=$2 actual=0 first_line terminal_command output
    shift 2
    "$rm_command" -f -- "$PACAUR_TEST_EXECUTED" "$PACAUR_TEST_PHASES" "$PACAUR_TEST_INSTALL" "$PACAUR_TEST_SUDO"
    "$rm_command" -f -- "$PACAUR_TEST_MAKEPKG_ARGS" "$PACAUR_TEST_LIST_ARGS" \
        "$PACAUR_TEST_DEPS_SUDO" "$PACAUR_TEST_DEPS_INSTALL" "$PACAUR_TEST_DEPS_PID"
    : > "$PACAUR_TEST_REQUEST"
    : > "$PACAUR_TEST_DOWNLOAD_REQUEST"
    if [[ ${PACAUR_TEST_TERMINAL:-0} == 1 ]]; then
        printf -v terminal_command '%q ' "$bash_command" "$program" "$@"
        "$timeout_command" --kill-after=2 20 "$script_command" --quiet --return --echo never \
            --command "exec $terminal_command" /dev/null \
            < "${PACAUR_TEST_INPUT:-$test_dir/yes}" > "$test_dir/stdout" 2> "$test_dir/stderr" || actual=$?
        output=$(< "$test_dir/stdout")
        printf '%s\n' "${output//$'\r'/}" > "$test_dir/stdout"
    else
        "$timeout_command" --kill-after=2 20 "$bash_command" "$program" "$@" \
            < "${PACAUR_TEST_INPUT:-$test_dir/yes}" > "$test_dir/stdout" 2> "$test_dir/stderr" || actual=$?
    fi
    [[ $actual == "$expected" ]] || fail "expected status $expected, got $actual for $*"
    [[ $(< "$test_dir/stderr") == *"$error_text"* || $(< "$test_dir/stdout") == *"$error_text"* ]] \
        || fail "missing error '$error_text'"
    workspace=''
    IFS= read -r first_line < "$test_dir/stdout" || true
    if [[ $first_line == 'Workspace (retained): '* ]]; then
        workspace=${first_line#'Workspace (retained): '}
        [[ -d $workspace && $workspace == "$TMPDIR/"* ]] || fail 'workspace was not retained'
    fi
    ((checks += 1))
}

no_execution() {
    [[ ! -e $PACAUR_TEST_EXECUTED && ! -e $PACAUR_TEST_PHASES && ! -e $PACAUR_TEST_SUDO ]] \
        || fail 'unreviewed or invalid snapshot reached execution'
}

no_install() {
    [[ ! -e $PACAUR_TEST_INSTALL && ! -e $PACAUR_TEST_SUDO ]] || fail 'failure reached installation'
}

check_sync 0 '' -h
[[ $(< "$test_dir/stdout") == *'-S PACKAGE'* ]] || fail 'help omits workflow command'
check_sync 2 'exactly one AUR package name' -S
check_sync 2 'exactly one AUR package name' -S ''
check_sync 2 'exactly one AUR package name' -S -h
check_sync 2 'exactly one AUR package name' -S one two
check_sync 2 'exactly one AUR package name' -S --syncdeps
check_sync 2 'exactly one AUR package name' -S split-tool --syncdeps --syncdeps
check_sync 2 'exactly one AUR package name' -S --syncdeps split-tool extra
check_sync 2 'exactly one AUR package name' -S split-tool --unknown
check_sync 2 'exactly one AUR package name' -S --syncdeps ''
check_sync 2 'unsupported arguments' --syncdeps
check_sync 2 '-m requires exactly one build directory' -m . --syncdeps
no_execution

dependencies=(curl jq tar gzip mktemp ln rm mkdir sed makepkg setsid pacman sudo)
for missing in "${dependencies[@]}"; do
    dependency_dir="$test_dir/without-$missing"
    mkdir "$dependency_dir"
    for dependency in "${dependencies[@]}"; do
        if [[ $dependency != "$missing" ]]; then
            ln -s -- "$(command -v "$dependency")" "$dependency_dir/$dependency"
        fi
    done
    PATH="$dependency_dir" check_sync 1 "Required command not found: $missing" -S split-tool
    [[ ! -s $PACAUR_TEST_REQUEST && -z $workspace ]] || fail 'missing dependency started a workflow'
done

PACAUR_TEST_CURL_STATUS=28 check_sync 1 'AUR request timed out' -S split-tool
no_execution
PACAUR_TEST_DOWNLOAD_STATUS=22 check_sync 1 'Snapshot download failed' -S split-tool
no_execution
PACAUR_TEST_DOWNLOAD_SIGNAL=TERM check_sync 143 '' -S split-tool
no_execution
partials=("$workspace"/.*.part.*)
[[ ${#partials[@]} == 0 ]] || fail 'interrupted download retained partial files'

for input in no blank; do
    PACAUR_TEST_INPUT="$test_dir/$input" check_sync 1 'Build cancelled' -S split-tool
    no_execution
    [[ -f $workspace/source/sample-base/PKGBUILD ]] || fail 'cancelled workflow lost source files'
    [[ $(< "$test_dir/stdout") == *'sub dir/file name.patch'* ]] || fail 'auxiliary file was not reviewed'
    [[ $(< "$test_dir/stdout") != *$'\033'* ]] || fail 'review printed an unescaped control character'
done
PACAUR_TEST_INPUT=/dev/null check_sync 1 'Build cancelled' -S split-tool
no_execution

check_sync 0 '' -S split-tool
[[ $(< "$PACAUR_TEST_PHASES") == $'build\nlist\nidentify\nidentify\nvalidate\nsudo\ninstall' ]] || fail 'unexpected workflow order'
mapfile -d '' -t arguments < "$PACAUR_TEST_INSTALL"
[[ ${#arguments[@]} == 3 && ${arguments[0]} == -U && ${arguments[1]} == -- \
    && ${arguments[2]} == "$workspace/source/sample-base/target-1-1-any.pkg.tar.zst" ]] || fail 'installed the wrong split package'
[[ -f $workspace/packages.txt && -f $workspace/source/sample-base/fixture-build.log ]] || fail 'lost manifest or build log'
mapfile -d '' -t arguments < "$PACAUR_TEST_MAKEPKG_ARGS"
[[ ${#arguments[@]} == 1 && ${arguments[0]} == --log ]] || fail 'default build enabled dependency installation'

# Dependency installation is opt-in, follows review, and never reaches --packagelist.
PACAUR_TEST_MISSING_DEPS=1 check_sync 1 'exit status 8' -S split-tool
[[ ! -e $PACAUR_TEST_DEPS_SUDO ]] || fail 'default build installed dependencies'
no_install
PACAUR_TEST_INPUT="$test_dir/no" PACAUR_TEST_MISSING_DEPS=1 check_sync 1 'Build cancelled' -S split-tool --syncdeps
no_execution
[[ ! -e $PACAUR_TEST_DEPS_SUDO ]] || fail 'review cancellation authenticated'
check_sync 0 '' -S split-tool --syncdeps
[[ ! -e $PACAUR_TEST_DEPS_SUDO ]] || fail 'satisfied dependencies requested installation'
mapfile -d '' -t arguments < "$PACAUR_TEST_MAKEPKG_ARGS"
[[ ${#arguments[@]} == 2 && ${arguments[0]} == --log && ${arguments[1]} == --syncdeps ]] || fail 'wrong syncdeps build arguments'
mapfile -d '' -t arguments < "$PACAUR_TEST_LIST_ARGS"
[[ ${#arguments[@]} == 1 && ${arguments[0]} == --packagelist ]] || fail 'package listing attempted dependency installation'
PACAUR_TEST_INPUT="$test_dir/deps-yes" PACAUR_TEST_MISSING_DEPS=1 check_sync 0 '' -S --syncdeps split-tool
[[ $(< "$PACAUR_TEST_PHASES") == $'deps-check\ndeps-sudo\ndeps-install\nbuild\nlist\nidentify\nidentify\nvalidate\nsudo\ninstall' ]] || fail 'wrong dependency workflow order'
mapfile -d '' -t arguments < "$PACAUR_TEST_DEPS_INSTALL"
[[ ${#arguments[@]} == 3 && ${arguments[0]} == -S && ${arguments[1]} == --asdeps && ${arguments[2]} == 'fixture-dep>=1' ]] || fail 'lost dependency constraints or default pacman options'
PACAUR_TEST_MISSING_DEPS=1 PACAUR_TEST_DEPS_STATUS=1 check_sync 1 'exit status 8' -S split-tool --syncdeps
no_install
[[ $(< "$PACAUR_TEST_PHASES") != *$'\nbuild'* ]] || fail 'unresolved dependencies reached building'
PACAUR_TEST_MISSING_DEPS=1 PACAUR_TEST_DEPS_AUTH_STATUS=1 check_sync 1 'exit status 8' -S split-tool --syncdeps
no_install
[[ ! -e $PACAUR_TEST_DEPS_INSTALL ]] || fail 'authentication failure reached dependency installation'
PACAUR_TEST_INPUT="$test_dir/deps-no" PACAUR_TEST_MISSING_DEPS=1 check_sync 1 'exit status 8' -S split-tool --syncdeps
no_install
[[ -f $workspace/source/sample-base/PKGBUILD ]] || fail 'dependency cancellation removed workspace'
PACAUR_TEST_INPUT="$test_dir/deps-yes" PACAUR_TEST_MISSING_DEPS=1 PACAUR_TEST_BUILD_STATUS=4 \
    check_sync 1 'exit status 4' -S split-tool --syncdeps
no_install
[[ -f $workspace/source/sample-base/build-work && -f $workspace/source/sample-base/fixture-build.log ]] || fail 'post-dependency failure removed work or logs'

# A real pseudo-terminal detects loss of /dev/tty caused by session detachment.
PACAUR_TEST_TERMINAL=1 PACAUR_TEST_AUTH_TTY=1 PACAUR_TEST_MISSING_DEPS=1 \
    PACAUR_TEST_INPUT="$test_dir/terminal-yes" check_sync 0 '' -S split-tool --syncdeps
[[ $(< "$PACAUR_TEST_PHASES") == *$'\ntty-auth\n'* && -f $PACAUR_TEST_INSTALL ]] || fail 'terminal authentication/confirmation did not finish'
for signal in HUP INT TERM; do
    case $signal in HUP) status=129 ;; INT) status=130 ;; TERM) status=143 ;; esac
    PACAUR_TEST_TERMINAL=1 PACAUR_TEST_MISSING_DEPS=1 PACAUR_TEST_DEPS_GROUP_SIGNAL=$signal \
        check_sync "$status" '' -S split-tool --syncdeps
    no_install
    [[ $(< "$PACAUR_TEST_PHASES") != *$'\nbuild'* ]] || fail 'terminal interruption reached building'
    [[ -f $workspace/source/sample-base/PKGBUILD ]] || fail 'terminal interruption removed workspace'
done

mkdir "$test_dir/package output" "$test_dir/build logs"
PKGDEST="$test_dir/package output" PKGEXT=.custom LOGDEST="$test_dir/build logs" check_sync 0 '' -S split-tool
mapfile -d '' -t arguments < "$PACAUR_TEST_INSTALL"
[[ ${arguments[2]} == "$test_dir/package output/target-1-1-any.custom" ]] || fail 'ignored makepkg output configuration'
[[ -f $test_dir/build\ logs/fixture-build.log ]] || fail 'lost configured build log'

for status in 4 8 130 143; do
    expected=1
    if (( status >= 128 )); then expected=$status; fi
    PACAUR_TEST_BUILD_STATUS=$status check_sync "$expected" "exit status $status" -S split-tool
    no_install
    [[ $(< "$PACAUR_TEST_PHASES") == build ]] || fail 'failed build reached package discovery'
    [[ -f $workspace/source/sample-base/build-work && -f $workspace/source/sample-base/fixture-build.log ]] || fail 'failure removed work or logs'
done
PACAUR_TEST_LIST_STATUS=4 check_sync 1 'makepkg failed' -S split-tool
no_install
PACAUR_TEST_LIST_STATUS=143 check_sync 143 'Build interrupted' -S split-tool
no_install
PACAUR_TEST_EMPTY_LIST=1 check_sync 1 'empty package list' -S split-tool
no_install
PACAUR_TEST_MISSING_OUTPUT=1 check_sync 1 'Listed package must be a readable file' -S split-tool
no_install
PACAUR_TEST_IDENTIFY_STATUS=1 check_sync 1 'Unable to identify built package' -S split-tool
no_install
PACAUR_TEST_OUTPUT_NAME=not-the-target check_sync 1 'No built package matches' -S split-tool
no_install
PACAUR_TEST_DUPLICATE_OUTPUT=1 check_sync 1 'Multiple built packages match' -S split-tool
no_install
PACAUR_TEST_VALIDATE_STATUS=1 check_sync 1 'Package validation failed' -S split-tool
no_install
PACAUR_TEST_SUDO_STATUS=1 check_sync 1 'Package installation failed' -S split-tool
[[ ! -e $PACAUR_TEST_INSTALL ]] || fail 'authentication failure installed a package'
PACAUR_TEST_INSTALL_STATUS=1 check_sync 1 'Package installation failed' -S split-tool
PACAUR_TEST_INPUT="$test_dir/install-no" check_sync 1 'Package installation failed' -S split-tool
[[ -f $workspace/source/sample-base/target-1-1-any.pkg.tar.zst ]] || fail 'installation cancellation removed the package'

# Every invalid entry must be rejected before any archive entry is extracted.
mkdir -p "$test_dir/extra/sample-base"
printf 'untrusted data\n' > "$test_dir/extra/evil"
for name in '../escape' 'sample-base/../../escape' '/tmp/pacaur-unexpected-entry' \
    'other-base/file' 'sample-base/./alias' 'sample-base//alias'; do
    tar -cf "$test_dir/bad.tar" -C "$test_dir/source" sample-base
    tar -rf "$test_dir/bad.tar" -C "$test_dir/extra" --transform="s|^evil$|$name|" evil
    gzip -c "$test_dir/bad.tar" > "$test_dir/bad.tar.gz"
    PACAUR_TEST_ARCHIVE="$test_dir/bad.tar.gz" check_sync 1 'Snapshot' -S split-tool
    no_execution
    [[ ! -e $workspace/source/sample-base ]] || fail 'unsafe archive was partially extracted'
done

ln -s /tmp "$test_dir/extra/sample-base/link"
printf 'hard link data\n' > "$test_dir/extra/sample-base/original"
ln "$test_dir/extra/sample-base/original" "$test_dir/extra/sample-base/hardlink"
mkfifo "$test_dir/extra/sample-base/fifo"
printf 'newline name\n' > "$test_dir/extra/sample-base/"$'line\nbreak'
printf 'backslash name\n' > "$test_dir/extra/sample-base/"'back\slash'
for kind in symlink hardlink fifo newline backslash duplicate; do
    tar -cf "$test_dir/bad.tar" -C "$test_dir/source" sample-base
    case $kind in
        symlink) tar -rf "$test_dir/bad.tar" -C "$test_dir/extra" sample-base/link ;;
        hardlink) tar -rf "$test_dir/bad.tar" -C "$test_dir/extra" sample-base/original sample-base/hardlink ;;
        fifo) tar -rf "$test_dir/bad.tar" -C "$test_dir/extra" sample-base/fifo ;;
        newline) tar -rf "$test_dir/bad.tar" -C "$test_dir/extra" sample-base/$'line\nbreak' ;;
        backslash) tar -rf "$test_dir/bad.tar" -C "$test_dir/extra" 'sample-base/back\slash' ;;
        duplicate) tar -rf "$test_dir/bad.tar" -C "$test_dir/source" sample-base/.SRCINFO ;;
    esac
    gzip -c "$test_dir/bad.tar" > "$test_dir/bad.tar.gz"
    PACAUR_TEST_ARCHIVE="$test_dir/bad.tar.gz" check_sync 1 'Snapshot contains' -S split-tool
    no_execution
    [[ ! -e $workspace/source/sample-base ]] || fail 'unsupported archive was partially extracted'
done

printf 'Passed %d non-root workflow checks.\n' "$checks"
