#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"
work_dir="$test_dir/download destination"
destination="$work_dir/sample-base.tar.gz"
mkdir -p "$work_dir" "$test_dir/source/sample-base"
export PACAUR_TEST_EXECUTED="$test_dir/recipe-executed"
cat > "$test_dir/source/sample-base/PKGBUILD" <<'RECIPE'
pkgname=split-tool
pkgver=1
pkgrel=1
printf 'This recipe must not execute.\n' > "$PACAUR_TEST_EXECUTED"
RECIPE
printf 'pkgbase = sample-base\n' > "$test_dir/source/sample-base/.SRCINFO"
tar -czf "$test_dir/valid.tar.gz" -C "$test_dir/source" sample-base
export PACAUR_TEST_ARCHIVE="$test_dir/valid.tar.gz"
cd -- "$work_dir"

write_metadata() {
    "$jq_command" -cn --arg name "${1:-split-tool}" --arg base "${2:-sample-base}" '{
        version: 5, type: "multiinfo", resultcount: 1,
        results: [{Name: $name, PackageBase: $base, URLPath: ("/cgit/aur.git/snapshot/" + $base + ".tar.gz")}]
    }' > "$PACAUR_TEST_RESPONSE"
}

assert_clean() {
    local -a partials=("$work_dir"/.*.part.*)
    (( ${#partials[@]} == 0 )) || fail 'temporary download files were left behind'
    [[ ! -e "$work_dir/sample-base" && ! -e $PACAUR_TEST_EXECUTED ]] || fail 'archive was extracted or executed'
}

assert_no_archive() {
    assert_clean
    [[ ! -e $destination && ! -L $destination ]] || fail 'a failed download created a final archive'
}

bash -n "$program"
check 0 '' -h
[[ $(< "$test_dir/stdout") == *'-d PACKAGE'* ]] || fail 'help does not describe downloading'
check 2 'requires exactly one package name' -d
check 2 'requires exactly one package name' -d ''
check 2 'requires exactly one package name' -d -h
check 2 'requires exactly one package name' -d one two
PATH="$test_dir/empty" check 2 'requires exactly one package name' -d
PATH="$test_dir/empty" check 0 '' -h

for missing in curl jq tar gzip mktemp ln rm; do
    dependency_dir="$test_dir/without-$missing"
    mkdir -- "$dependency_dir"
    for dependency in curl jq tar gzip mktemp ln rm; do
        if [[ $dependency != "$missing" ]]; then
            ln -s -- "$(command -v "$dependency")" "$dependency_dir/$dependency"
        fi
    done
    PATH="$dependency_dir" check 1 "Required command not found: $missing" -d split-tool
    [[ ! -s $PACAUR_TEST_REQUEST ]] || fail 'missing dependency triggered a request'
    assert_no_archive
done

write_metadata sample-base
check 0 '' -d sample-base
[[ $(< "$test_dir/stdout") == "$destination" ]] || fail 'download did not report its saved path'
original_hash=$(sha256sum -- "$PACAUR_TEST_ARCHIVE")
downloaded_hash=$(sha256sum -- "$destination")
[[ ${original_hash%% *} == "${downloaded_hash%% *}" ]] || fail 'saved archive differs from the download'
assert_clean
rm -- "$destination"

write_metadata
check 0 '' -d split-tool
[[ -f $destination && ! -e "$work_dir/split-tool.tar.gz" ]] || fail 'split package did not use its package base'
mapfile -d '' -t download_arguments < "$PACAUR_TEST_DOWNLOAD_REQUEST"
[[ ${download_arguments[-1]} == 'https://aur.archlinux.org/cgit/aur.git/snapshot/sample-base.tar.gz' ]] || fail 'wrong snapshot URL'
assert_clean
rm -- "$destination"

printf 'original file' > "$destination"
check 1 'Target already exists' -d split-tool
[[ $(< "$destination") == 'original file' && ! -s $PACAUR_TEST_DOWNLOAD_REQUEST ]] || fail 'existing file was changed or redownloaded'
assert_clean
rm -- "$destination"

mkdir -- "$destination"
check 1 'Target already exists' -d split-tool
[[ -d $destination && ! -s $PACAUR_TEST_DOWNLOAD_REQUEST ]] || fail 'existing directory was changed'
assert_clean
rmdir -- "$destination"

printf 'protected file' > "$test_dir/protected"
ln -s -- "$test_dir/protected" "$destination"
check 1 'Target already exists' -d split-tool
[[ -L $destination && $(< "$test_dir/protected") == 'protected file' ]] || fail 'symlink target was modified'
assert_clean
rm -- "$destination"
ln -s -- "$test_dir/absent" "$destination"
check 1 'Target already exists' -d split-tool
[[ -L $destination && ! -e "$test_dir/absent" ]] || fail 'dangling symlink was overwritten'
assert_clean
rm -- "$destination"

PACAUR_TEST_COMPETING_TARGET="$destination" check 1 'Unable to save archive without overwriting' -d split-tool
[[ $(< "$destination") == 'concurrent file' ]] || fail 'concurrently created target was overwritten'
assert_clean
rm -- "$destination"

for mutation in \
    '.results[0].Name = "other-package"' \
    '.results[0].PackageBase = null' \
    '.results[0].PackageBase = "../outside"' \
    '.results[0].PackageBase = "/tmp/outside"' \
    '.results[0].PackageBase = "sample-base\n"' \
    '.results[0].URLPath = null' \
    '.results[0].URLPath = "https://example.com/archive.tar.gz"' \
    '.results[0].URLPath = "//example.com/archive.tar.gz"' \
    '.results[0].URLPath = "/cgit/aur.git/snapshot/other-base.tar.gz"' \
    '.results[0].URLPath += "?other=1"'; do
    write_metadata
    change_response "$mutation"
    check 1 'Unexpected AUR download data' -d split-tool
    [[ ! -s $PACAUR_TEST_DOWNLOAD_REQUEST ]] || fail 'invalid metadata triggered an archive request'
    assert_no_archive
done

printf '%s\n' '{"version":5,"type":"multiinfo","resultcount":0,"results":[]}' > "$PACAUR_TEST_RESPONSE"
check 1 'AUR package not found' -d split-tool
assert_no_archive
printf '<html>Unavailable</html>\n' > "$PACAUR_TEST_RESPONSE"
check 1 'invalid JSON response' -d split-tool
assert_no_archive
write_metadata
PACAUR_TEST_CURL_STATUS=28 check 1 'AUR request timed out' -d split-tool
assert_no_archive

for download_status in 6 22 23 28; do
    PACAUR_TEST_DOWNLOAD_STATUS=$download_status check 1 'Snapshot download' -d split-tool
    assert_no_archive
done
for signal in HUP INT TERM; do
    case $signal in HUP) expected_status=129 ;; INT) expected_status=130 ;; TERM) expected_status=143 ;; esac
    PACAUR_TEST_DOWNLOAD_SIGNAL=$signal check "$expected_status" '' -d split-tool
    assert_no_archive
done

printf '<html>Not a snapshot</html>\n' > "$test_dir/html.tar.gz"
: > "$test_dir/empty.tar.gz"
head -c -8 -- "$test_dir/valid.tar.gz" > "$test_dir/truncated.tar.gz"
for invalid in html empty truncated; do
    PACAUR_TEST_ARCHIVE="$test_dir/$invalid.tar.gz" check 1 'not a valid gzip archive' -d split-tool
    assert_no_archive
done

printf 'not a tar archive\n' | gzip > "$test_dir/not-tar.tar.gz"
PACAUR_TEST_ARCHIVE="$test_dir/not-tar.tar.gz" check 1 'not a readable tar archive' -d split-tool
assert_no_archive
tar -czf "$test_dir/no-recipe.tar.gz" -C "$test_dir/source" sample-base/.SRCINFO
PACAUR_TEST_ARCHIVE="$test_dir/no-recipe.tar.gz" check 1 'PKGBUILD' -d split-tool
assert_no_archive
mkdir -p "$test_dir/wrong-base/other-base"
cp -- "$test_dir/source/sample-base/PKGBUILD" "$test_dir/wrong-base/other-base/PKGBUILD"
tar -czf "$test_dir/wrong-base.tar.gz" -C "$test_dir/wrong-base" other-base
PACAUR_TEST_ARCHIVE="$test_dir/wrong-base.tar.gz" check 1 'PKGBUILD' -d split-tool
assert_no_archive

mkdir -p "$test_dir/directory-recipe/sample-base/PKGBUILD" "$test_dir/link-recipe/sample-base"
tar -czf "$test_dir/directory-recipe.tar.gz" -C "$test_dir/directory-recipe" sample-base
PACAUR_TEST_ARCHIVE="$test_dir/directory-recipe.tar.gz" check 1 'regular' -d split-tool
assert_no_archive
ln -s .SRCINFO "$test_dir/link-recipe/sample-base/PKGBUILD"
tar -czf "$test_dir/link-recipe.tar.gz" -C "$test_dir/link-recipe" sample-base
PACAUR_TEST_ARCHIVE="$test_dir/link-recipe.tar.gz" check 1 'regular' -d split-tool
assert_no_archive
tar -cf "$test_dir/duplicate.tar" -C "$test_dir/source" sample-base/PKGBUILD
tar -rf "$test_dir/duplicate.tar" -C "$test_dir/source" sample-base/PKGBUILD
gzip -c -- "$test_dir/duplicate.tar" > "$test_dir/duplicate.tar.gz"
PACAUR_TEST_ARCHIVE="$test_dir/duplicate.tar.gz" check 1 'regular' -d split-tool
assert_no_archive

readonly_dir="$test_dir/readonly"
mkdir -- "$readonly_dir"
chmod 555 "$readonly_dir"
readonly_command=("$bash_command" "$program" -d split-tool)
if (( EUID == 0 )); then
    command -v runuser > /dev/null || fail 'Root permission tests require runuser.'
    id nobody > /dev/null || fail 'Root permission tests require a nobody user.'
    chmod a+rx "$test_dir"
    chmod a+rw "$PACAUR_TEST_REQUEST" "$PACAUR_TEST_DOWNLOAD_REQUEST"
    readonly_command=(runuser -u nobody -- "${readonly_command[@]}")
fi
actual_status=0
(cd -- "$readonly_dir" && "${readonly_command[@]}") > "$test_dir/stdout" 2> "$test_dir/stderr" || actual_status=$?
[[ $actual_status == 1 && ! -s "$test_dir/stdout" ]] || fail 'download unexpectedly succeeded in an unwritable directory'
[[ $(< "$test_dir/stderr") == *'Unable to create a temporary archive'* ]] || fail 'unwritable directory failure was not reported'
readonly_partials=("$readonly_dir"/.*.part.*)
[[ ! -e "$readonly_dir/sample-base.tar.gz" && ${#readonly_partials[@]} == 0 ]] || fail 'unwritable directory contains download files'
((checks += 1))

printf 'PASS: %d checks covering snapshots, split packages, existing targets, archive integrity and failure cleanup\n' "$checks"
