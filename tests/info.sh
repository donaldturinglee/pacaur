#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"

write_package() {
    "$jq_command" -cn '{
        version: 5, type: "multiinfo", resultcount: 1,
        results: [{Name: "sample+pkg", Version: "1.2.3-1", Description: "Example package", Maintainer: "alice"}]
    }' > "$PACAUR_TEST_RESPONSE"
}

bash -n "$program"
check 0 '' -h
help_output=$(< "$test_dir/stdout")
[[ $help_output == *'-i PACKAGE'* ]] || fail 'help does not describe querying'
check 0 ''
[[ $(< "$test_dir/stdout") == "$help_output" ]] || fail 'no-argument help differs'

check 2 'requires exactly one package name' -i
check 2 'requires exactly one package name' -i ''
check 2 'requires exactly one package name' -i -h
check 2 'requires exactly one package name' -i one two
check 2 'unsupported arguments' --unknown
check 2 'unsupported arguments' -h extra

PATH="$test_dir/empty" check 0 '' -h
PATH="$test_dir/empty" check 0 ''
PATH="$test_dir/empty" check 2 'requires exactly one package name' -i
PATH="$test_dir/jq-only" check 1 'Required command not found: curl' -i sample+pkg
PATH="$test_dir/curl-only" check 1 'Required command not found: jq' -i sample+pkg

write_package
check 0 '' -i sample+pkg
expected_output=$'Name        : sample+pkg\nVersion     : 1.2.3-1\nDescription : Example package\nMaintainer  : alice\nAUR URL     : https://aur.archlinux.org/packages/sample%2Bpkg'
[[ $(< "$test_dir/stdout") == "$expected_output" ]] || fail 'incorrect package information'

for replacement in null empty; do
    # Test null and empty optional fields independently.
    if [[ $replacement == null ]]; then
        change_response '.results[0].Description = null | .results[0].Maintainer = null'
    else
        change_response '.results[0].Description = "" | .results[0].Maintainer = ""'
    fi
    check 0 '' -i sample+pkg
    output=$(< "$test_dir/stdout")
    [[ $output == *'Description : (none)'* && $output == *'Maintainer  : (none)'* ]] || fail 'optional fields lack defaults'
done
change_response 'del(.results[0].Description, .results[0].Maintainer)'
check 0 '' -i sample+pkg
[[ $(< "$test_dir/stdout") == *'Maintainer  : (none)'* ]] || fail 'missing optional field lacks a default'

printf '%s\n' '{"version":5,"type":"multiinfo","resultcount":0,"results":[]}' > "$PACAUR_TEST_RESPONSE"
check 1 'AUR package not found: sample+pkg' -i sample+pkg
printf '%s\n' '{"version":5,"type":"error","error":"Service unavailable"}' > "$PACAUR_TEST_RESPONSE"
check 1 'AUR API error: Service unavailable' -i sample+pkg

for response in '<html>Unavailable</html>' '' '[]' '{} {}'; do
    printf '%s\n' "$response" > "$PACAUR_TEST_RESPONSE"
    check 1 'invalid JSON response' -i sample+pkg
done

for mutation in \
    '.version = 4' \
    '.type = "search"' \
    '.results = {}' \
    '.resultcount = 0' \
    '.resultcount = 2 | .results += .results' \
    '.results[0] = null' \
    '.results[0].Name = "different-package"' \
    '.results[0].Version = null' \
    '.results[0].Version = ""' \
    '.results[0].Description = 42' \
    '.results[0].Maintainer = []'; do
    write_package
    change_response "$mutation"
    check 1 'Unexpected AUR' -i sample+pkg
done

PACAUR_TEST_CURL_STATUS=28 check 1 'request timed out' -i sample+pkg
PACAUR_TEST_CURL_STATUS=22 check 1 'HTTP error' -i sample+pkg
PACAUR_TEST_CURL_STATUS=6 check 1 'curl exit status 6' -i sample+pkg

printf 'PASS: %d checks covering help, arguments, dependencies, package information and failure handling\n' "$checks"
