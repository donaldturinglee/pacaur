#!/usr/bin/env bash
set -euo pipefail

source "$(dirname -- "${BASH_SOURCE[0]}")/helpers.sh"
[[ -n $real_curl ]] || fail 'Search tests require curl.'

write_search() {
    "$jq_command" -cn '{
        version: 5, type: "search", resultcount: 3,
        results: [
            {Name: "zeta", Version: "2.0-1", Description: "Last package"},
            {Name: "alpha", Version: "1.0-1", Description: "First package"},
            {Name: "middle", Version: "3.0-1", Description: null}
        ]
    }' > "$PACAUR_TEST_RESPONSE"
}

check_request_encoding() {
    local keywords=$1 actual_url index destinations=0
    local -a request_arguments
    mapfile -d '' -t request_arguments < "$PACAUR_TEST_REQUEST"
    for index in "${!request_arguments[@]}"; do
        if [[ ${request_arguments[index]} == 'https://aur.archlinux.org/rpc/' ]]; then
            request_arguments[index]='http://127.0.0.1:1/rpc/'
            ((destinations += 1))
        fi
    done
    [[ $destinations == 1 ]] || fail 'request does not target the AUR RPC endpoint'

    # A nonexistent local socket lets curl build the URL without reaching a server.
    actual_url=$("$real_curl" "${request_arguments[@]}" --noproxy '*' --proxy '' \
        --unix-socket "$test_dir/no-server.sock" --connect-timeout 0.1 --max-time 0.1 \
        --output /dev/null --write-out '%{url_effective}' 2> /dev/null) || true
    [[ $actual_url == 'http://127.0.0.1:1/rpc/?'* ]] || fail 'curl did not build a query URL'
    "$jq_command" -en --arg url "$actual_url" --arg keywords "$keywords" '
        ($url | split("?")[1] | split("&") | map(gsub("\\+"; "%20") | ascii_downcase) | sort) ==
        (["v=5", "type=search", "by=name-desc", "arg=" + ($keywords | @uri)] |
            map(ascii_downcase) | sort)
    ' > /dev/null || fail "incorrect query encoding for '$keywords': $actual_url"
}

bash -n "$program"
check 0 '' -h
[[ $(< "$test_dir/stdout") == *'-s KEYWORDS'* ]] || fail 'help does not describe search'

for keywords in '' a -h '  ' $'\t\n'; do
    check 2 'at least 2 characters' -s "$keywords"
    [[ ! -s "$PACAUR_TEST_REQUEST" ]] || fail 'invalid search triggered a request'
done
check 2 'at least 2 characters' -s
check 2 'at least 2 characters' -s one two
check 2 'at least 2 characters' -s query -i package
PATH="$test_dir/empty" check 2 'at least 2 characters' -s a
PATH="$test_dir/jq-only" check 1 'Required command not found: curl' -s query
PATH="$test_dir/curl-only" check 1 'Required command not found: jq' -s query
# Language-neutral symbols keep multibyte character coverage in the C locale.
LC_ALL=C check 2 'at least 2 characters' -s '★'
[[ ! -s "$PACAUR_TEST_REQUEST" ]] || fail 'single Unicode character triggered a request'

write_search
check 0 '' -s query
expected_output=$'aur/alpha 1.0-1\n    First package\naur/middle 3.0-1\n    (none)\naur/zeta 2.0-1\n    Last package'
[[ $(< "$test_dir/stdout") == "$expected_output" ]] || fail 'incorrect search output or ordering'
check_request_encoding query

check 0 '' -s 'c++ & tools★/=1%?'
check_request_encoding 'c++ & tools★/=1%?'
LC_ALL=C check 0 '' -s '☆★'
check_request_encoding '☆★'

change_response '.results = [.results[0]] | .resultcount = 1'
check 0 '' -s query
[[ $(< "$test_dir/stdout") == $'aur/zeta 2.0-1\n    Last package' ]] || fail 'incorrect single result'
change_response '.results[0].Description = ""'
check 0 '' -s query
[[ $(< "$test_dir/stdout") == *'    (none)' ]] || fail 'empty description lacks a default'
change_response 'del(.results[0].Description)'
check 0 '' -s query
[[ $(< "$test_dir/stdout") == *'    (none)' ]] || fail 'missing description lacks a default'

printf '%s\n' '{"version":5,"type":"search","resultcount":0,"results":[]}' > "$PACAUR_TEST_RESPONSE"
check 0 '' -s query
[[ $(< "$test_dir/stdout") == 'No matching packages found.' ]] || fail 'missing no-match message'

for response in '<html>Unavailable</html>' '' '[]' '{} {}'; do
    printf '%s\n' "$response" > "$PACAUR_TEST_RESPONSE"
    check 1 'invalid JSON response' -s query
done

for mutation in \
    '.version = 4' \
    '.type = "multiinfo"' \
    '.results = {}' \
    '.resultcount = "3"' \
    '.resultcount = 1' \
    '.results[2] = null' \
    '.results[2].Name = null' \
    '.results[2].Name = ""' \
    '.results[2].Version = null' \
    '.results[2].Version = ""' \
    '.results[2].Description = []'; do
    write_search
    change_response "$mutation"
    check 1 'Unexpected AUR' -s query
done

printf '%s\n' '{"version":5,"type":"error","error":"Too many package results."}' > "$PACAUR_TEST_RESPONSE"
check 1 'AUR API error: Too many package results.' -s query
PACAUR_TEST_CURL_STATUS=28 check 1 'request timed out' -s query
PACAUR_TEST_CURL_STATUS=22 check 1 'HTTP error' -s query
PACAUR_TEST_CURL_STATUS=6 check 1 'curl exit status 6' -s query

printf 'PASS: %d checks covering search, sorting, empty results, request encoding and failure handling\n' "$checks"
