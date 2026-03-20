#!/usr/bin/env bash
# t/load/run_all.sh
#
# Runs the load test suite and emits a summary.
#
# Usage:
#   bash t/load/run_all.sh            # all tests
#   bash t/load/run_all.sh 01 03      # specific tests by number prefix

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FILTER=("$@")

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BOLD='\033[1m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; BOLD=''; RESET=''
fi

# -- Signal handling --------------------------------------------------------

CURRENT_TEST_PID=""

_interrupted_cleanup() {
    echo ""
    echo "# interrupted — shutting down"
    if [ -n "${CURRENT_TEST_PID:-}" ]; then
        kill -- -"${CURRENT_TEST_PID}" 2>/dev/null || true
        wait "${CURRENT_TEST_PID}" 2>/dev/null || true
    fi
    pkill -TERM -f "nginx-static\|nginx-dynamic\|nginx/sbin" 2>/dev/null || true
    echo "# done"
    exit 130
}

trap '_interrupted_cleanup' INT TERM

# -- Collect scripts --------------------------------------------------------

if [ "${#FILTER[@]}" -gt 0 ]; then
    TESTS=()
    for prefix in "${FILTER[@]}"; do
        while IFS= read -r f; do TESTS+=("$f"); done \
            < <(find "$SCRIPT_DIR" -maxdepth 1 -name "${prefix}*.sh" | sort)
    done
else
    mapfile -t TESTS < <(find "$SCRIPT_DIR" -maxdepth 1 -name '[0-9]*.sh' | sort)
fi

[ "${#TESTS[@]}" -eq 0 ] && { echo "No test scripts found in $SCRIPT_DIR" >&2; exit 2; }

# -- Pre-flight -------------------------------------------------------------

NGINX_BIN="${TEST_NGINX_BINARY:-nginx}"

for bin in "$NGINX_BIN" curl nc awk python3; do
    command -v "$bin" >/dev/null 2>&1 \
        || { printf "${RED}MISSING:${RESET} %s\n" "$bin" >&2; exit 2; }
done

printf "${BOLD}nginx:${RESET} %s (%s)\n" "$NGINX_BIN" \
    "$("$NGINX_BIN" -v 2>&1 | head -1)"
printf "${BOLD}mode: ${RESET} %s\n" "${TEST_NGINX_MODULE_MODE:-static}"
echo ""

# -- Run --------------------------------------------------------------------

SUITE_PASSED=0; SUITE_FAILED=0; SUITE_ERRORS=0
RESULTS=()

for script in "${TESTS[@]}"; do
    name="$(basename "$script" .sh)"
    printf "${BOLD}==> %s${RESET}\n" "$name"

    tmpout=$(mktemp)
    set +e
    setsid timeout 300 bash "$script" > "$tmpout" 2>&1 &
    CURRENT_TEST_PID=$!
    wait "${CURRENT_TEST_PID}"
    exit_code=$?
    CURRENT_TEST_PID=""
    set -e

    cat "$tmpout"
    echo ""

    passed=$(grep -c '^ok '      "$tmpout" 2>/dev/null || true); passed="${passed:-0}"
    failed=$(grep -c '^not ok '  "$tmpout" 2>/dev/null || true); failed="${failed:-0}"
    bailed=$(grep -c '^Bail out!' "$tmpout" 2>/dev/null || true); bailed="${bailed:-0}"

    rm -f "$tmpout"

    if [ "$exit_code" -eq 124 ]; then
        printf "${YELLOW}TIMEOUT${RESET}: %s\n" "$name"
        SUITE_ERRORS=$(( SUITE_ERRORS + 1 ))
        RESULTS+=("TIMEOUT $name")
    elif [ "$exit_code" -ne 0 ] || [ "$failed" -gt 0 ] || [ "$bailed" -gt 0 ]; then
        printf "${RED}FAIL${RESET}: %s (%d passed, %d failed)\n" "$name" "$passed" "$failed"
        SUITE_FAILED=$(( SUITE_FAILED + 1 ))
        RESULTS+=("FAIL $name ($passed passed, $failed failed)")
    else
        printf "${GREEN}PASS${RESET}: %s (%d tests)\n" "$name" "$passed"
        SUITE_PASSED=$(( SUITE_PASSED + 1 ))
        RESULTS+=("PASS $name")
    fi

    echo ""
    sleep 2
done

# -- Summary ----------------------------------------------------------------

echo "══════════════════════════════════════════════"
printf "${BOLD}Results${RESET}\n"
echo "══════════════════════════════════════════════"
for r in "${RESULTS[@]}"; do
    case "$r" in
        PASS*)    printf "  ${GREEN}✓${RESET} %s\n" "${r#PASS }"    ;;
        FAIL*)    printf "  ${RED}✗${RESET} %s\n"   "${r#FAIL }"    ;;
        TIMEOUT*) printf "  ${YELLOW}⚠${RESET} %s\n" "${r#TIMEOUT }" ;;
    esac
done
echo ""
printf "Suites: %d  ${GREEN}Passed: %d${RESET}  ${RED}Failed: %d${RESET}  ${YELLOW}Errors: %d${RESET}\n" \
    "$(( SUITE_PASSED + SUITE_FAILED + SUITE_ERRORS ))" \
    "$SUITE_PASSED" "$SUITE_FAILED" "$SUITE_ERRORS"
echo "══════════════════════════════════════════════"

[ $(( SUITE_FAILED + SUITE_ERRORS )) -eq 0 ]
