#!/usr/bin/env bash
# Runs all test scripts in infra/remote-access/tests/ and prints a structured summary report.
set -uo pipefail

TESTS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SCRIPT_NAME=$(basename "${BASH_SOURCE[0]}")

# Collect all other .sh test scripts dynamically
TEST_SCRIPTS=()
for test_file in "$TESTS_DIR"/*.sh; do
    [[ -f "$test_file" ]] || continue
    [[ $(basename "$test_file") != "$SCRIPT_NAME" ]] || continue
    TEST_SCRIPTS+=("$test_file")
done

if (( ${#TEST_SCRIPTS[@]} == 0 )); then
    echo "No test scripts found in $TESTS_DIR" >&2
    exit 1
fi

TEST_TIMEOUT=${TEST_TIMEOUT:-180}
REPORT_ENTRIES=()
TOTAL_PASSED=0
TOTAL_FAILED=0
ANY_FAILURE=0

for test_file in "${TEST_SCRIPTS[@]}"; do
    test_name=$(basename "$test_file")
    echo "==> Running $test_name..."

    output_file=$(mktemp)
    timeout "$TEST_TIMEOUT" bash "$test_file" "$@" > "$output_file" 2>&1
    status=$?

    passed=0
    failed=0
    skipped=0
    skip_reason=""
    failures=()
    cur_fail=""
    in_fail=0

    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^[[:space:]]*ok[[:space:]]+ ]]; then
            if (( in_fail )); then
                failures+=("$cur_fail")
                cur_fail=""
                in_fail=0
            fi
            (( passed++ ))
        elif [[ $line =~ ^[[:space:]]*FAIL[[:space:]]+ ]]; then
            if (( in_fail )); then
                failures+=("$cur_fail")
                cur_fail=""
            fi
            (( failed++ ))
            in_fail=1
            cur_fail="  $line"
        elif [[ $line =~ ^[[:space:]]*SKIP[[:space:]]+(.*)$ ]]; then
            skipped=1
            skip_reason="${BASH_REMATCH[1]}"
        elif (( in_fail )); then
            cur_fail+=$'\n'"  $line"
        fi
    done < "$output_file"

    if (( in_fail )); then
        failures+=("$cur_fail")
    fi

    total=$(( passed + failed ))

    # If script skipped, timed out, or failed without emitting standard test output lines
    if (( skipped && total == 0 )); then
        entry="[$test_name] - 0/0 passed, 0/0 failed (SKIPPED: ${skip_reason:-cluster offline})."$'\n'
        entry+="Failures list: None"
    elif (( status == 124 )); then
        total=$(( total + 1 ))
        failed=$(( failed + 1 ))
        failures+=("  Test timed out after ${TEST_TIMEOUT}s")
        entry="[$test_name] - ${passed}/${total} passed, ${failed}/${total} failed."$'\n'
        entry+="Failures list:"$'\n'
        for f in "${failures[@]}"; do
            entry+="$f"$'\n'
        done
        entry="${entry%$'\n'}"
        ANY_FAILURE=1
    elif (( total == 0 )); then
        if (( status != 0 )); then
            total=1
            failed=1
            fail_desc="  Script exited with status $status:"
            while IFS= read -r line || [[ -n $line ]]; do
                fail_desc+=$'\n'"    $line"
            done < "$output_file"
            failures+=("$fail_desc")
            entry="[$test_name] - ${passed}/${total} passed, ${failed}/${total} failed."$'\n'
            entry+="Failures list:"$'\n'
            for f in "${failures[@]}"; do
                entry+="$f"$'\n'
            done
            entry="${entry%$'\n'}"
            ANY_FAILURE=1
        fi
    else
        entry="[$test_name] - ${passed}/${total} passed, ${failed}/${total} failed."$'\n'
        if (( failed > 0 )); then
            ANY_FAILURE=1
            entry+="Failures list:"$'\n'
            for f in "${failures[@]}"; do
                entry+="$f"$'\n'
            done
            entry="${entry%$'\n'}"
        else
            entry+="Failures list: None"
        fi
    fi

    rm -f "$output_file"

    TOTAL_PASSED=$(( TOTAL_PASSED + passed ))
    TOTAL_FAILED=$(( TOTAL_FAILED + failed ))

    REPORT_ENTRIES+=("$entry")
done

echo
echo "=================================================="
echo "                  TEST REPORT"
echo "=================================================="
for entry in "${REPORT_ENTRIES[@]}"; do
    printf "%s\n\n" "$entry"
done

if (( ANY_FAILURE == 0 )); then
    echo "All tests passed successfully!"
    exit 0
else
    echo "Some tests failed. See details above."
    exit 1
fi
