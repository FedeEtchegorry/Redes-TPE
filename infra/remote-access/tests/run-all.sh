#!/usr/bin/env bash
# Runs the tests of this directory and prints a report. Arguments go to each test.
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEST_TIMEOUT=${TEST_TIMEOUT:-180}
REPORT=
ANY_FAILURE=0

for test_file in "$TESTS_DIR"/*.sh; do
    name=$(basename "$test_file")
    [[ $name != run-all.sh ]] || continue
    echo "==> Running $name..."

    output_file=$(mktemp)
    timeout "$TEST_TIMEOUT" bash "$test_file" "$@" > "$output_file" 2>&1
    status=$?
    output=$(< "$output_file")
    rm -f "$output_file"

    passed=$(grep -cE '^[[:space:]]*ok[[:space:]]' <<< "$output")
    failed=$(grep -cE '^[[:space:]]*FAIL[[:space:]]' <<< "$output")
    # Each FAIL line with the detail lines under it.
    failures=$(awk '/^[ \t]*ok[ \t]/ {f=0} /^[ \t]*FAIL[ \t]/ {f=1} f {print "  " $0}' <<< "$output")

    # A script that ends badly without a FAIL line is a failure too, as is a timeout.
    note=
    if (( status == 124 )); then
        note="Test timed out after ${TEST_TIMEOUT}s"
    elif (( status != 0 && failed == 0 )); then
        note="Script exited with status $status:"$'\n'"$(sed 's/^/    /' <<< "$output")"
    fi
    if [[ -n $note ]]; then
        (( failed++ ))
        failures+=${failures:+$'\n'}"  $note"
    fi

    total=$(( passed + failed ))
    entry="[$name] - $passed/$total passed, $failed/$total failed."
    if (( failed > 0 )); then
        ANY_FAILURE=1
        entry+=$'\n'"Failures list:"$'\n'"$failures"
    else
        skip=$(sed -n 's/^[[:space:]]*SKIP[[:space:]]\{1,\}//p' <<< "$output" | head -n 1)
        [[ -z $skip || $total != 0 ]] || entry="${entry%.} (SKIPPED: $skip)."
        entry+=$'\n'"Failures list: None"
    fi
    REPORT+="$entry"$'\n\n'
done

echo
echo "=================================================="
echo "                  TEST REPORT"
echo "=================================================="
printf '%s' "$REPORT"

if (( ANY_FAILURE == 0 )); then
    echo "All tests passed successfully!"
else
    echo "Some tests failed. See details above."
    exit 1
fi
