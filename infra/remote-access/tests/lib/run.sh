# shellcheck shell=bash
# Sourced by the tests. run DESCRIPTION COMMAND...: prints "ok" or "FAIL" (the format run-all.sh reads).
FAILED=0

run() {
    local description=$1 output line
    shift
    if output=$("$@" 2>&1); then
        echo "ok    $description"
    else
        echo "FAIL  $description"
        while IFS= read -r line; do echo "      $line"; done <<< "$output"
        FAILED=1
    fi
}
