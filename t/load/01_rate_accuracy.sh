#!/usr/bin/env bash
# t/load/01_rate_accuracy.sh
#
# Verify that a single rate-limited download stays within the configured
# ceiling with meaningful accuracy.
#
# WHY THESE NUMBERS:
#   The nginx rate limiter sends the first sendfile_max_chunk bytes at full
#   speed before the timer-based throttle engages. For a 50 KB/s limit the
#   default chunk is 0 (unlimited until r->limit_rate_after), meaning the
#   first write call can send everything before the limiter intervenes on
#   small files. We use a 2 MB file so the steady-state throttle dominates
#   the measurement: burst ≈ 128 KB, file = 2048 KB, burst fraction < 7%.
#   At 50 KB/s a 2 MB transfer takes ~40s, giving the rate limiter enough
#   cycles to produce a statistically meaningful average.
#
#   The un-limited baseline uses the same file on /open/. On a loopback
#   interface it should complete in under 3s regardless of file size.

source "$(dirname "$0")/helpers.sh"

# 1. nginx serves the test file (HTTP 200)
# 2. Un-limited download completes in under 3s (loopback baseline)
# 3. Rate-limited download takes >= 30s (lower-bound: burst < 25% of total)
# 4. Rate-limited download takes <= 60s (upper-bound: not completely stalled)
# 5. Throughput within ±25% of configured limit
tap_plan 5

trap _cleanup EXIT
check_requirements

RATE_BYTES=51200       # 50 KB/s
RATE_DIRECTIVE="50k"
FILE_BYTES=2097152     # 2 MB — burst fraction < 7%, steady state dominates

init_test_dir "rate-accuracy"
make_file "$TEST_DIR/files/testfile.bin" "$FILE_BYTES"
mkdir -p "$TEST_DIR/open"
chmod 755 "$TEST_DIR/open"
make_file "$TEST_DIR/open/testfile.bin" "$FILE_BYTES"

write_nginx_conf "1m" "$RATE_DIRECTIVE"
start_nginx

# Test 1
assert_http_status \
    "http://127.0.0.1:${TEST_PORT}/files/testfile.bin" "200" \
    "nginx serves test file"

# Test 2 — un-limited baseline
open_start=$(date +%s%N)
curl -s -o /dev/null "http://127.0.0.1:${TEST_PORT}/open/testfile.bin" || true
open_elapsed=$(( ($(date +%s%N) - open_start + 999999999) / 1000000000 ))
tap_diag "un-limited elapsed: ${open_elapsed}s"
if [ "$open_elapsed" -lt 3 ]; then
    tap_ok "un-limited download under 3s (${open_elapsed}s)"
else
    tap_fail "un-limited baseline" "took ${open_elapsed}s — runner may be overloaded"
fi

# Tests 3-5 — rate-limited download
DL_OUT="$TEST_DIR/downloads/testfile.bin"
mkdir -p "$TEST_DIR/downloads"
tap_diag "starting rate-limited download (~40s expected at 50KB/s)..."

limited_start=$(date +%s%N)
curl -s --max-time 120 -o "$DL_OUT" \
    "http://127.0.0.1:${TEST_PORT}/files/testfile.bin"
limited_elapsed=$(( ($(date +%s%N) - limited_start + 999999999) / 1000000000 ))
tap_diag "rate-limited elapsed: ${limited_elapsed}s"

# Test 3 — lower bound: must take at least 30s (burst < 25% of 40s expected)
if [ "$limited_elapsed" -ge 30 ]; then
    tap_ok "rate-limited download >= 30s (${limited_elapsed}s)"
else
    tap_fail "rate limit lower bound" \
        "completed in ${limited_elapsed}s — expected >=30s at 50KB/s for 2MB"
fi

# Test 4 — upper bound: must finish within 60s (rate not slower than 50% of limit)
if [ "$limited_elapsed" -le 60 ]; then
    tap_ok "rate-limited download <= 60s (${limited_elapsed}s)"
else
    tap_fail "rate limit upper bound" \
        "took ${limited_elapsed}s — rate limiter may be over-throttling"
fi

# Test 5 — throughput accuracy ±25%
# Tighter than other tests because the large file makes the measurement reliable.
dl_bytes=$(wc -c < "$DL_OUT" 2>/dev/null || echo 0)
if [ "$dl_bytes" -eq "$FILE_BYTES" ] && [ "$limited_elapsed" -gt 0 ]; then
    assert_rate_within_bounds \
        "$FILE_BYTES" "$limited_elapsed" "$RATE_BYTES" 25 \
        "throughput within ±25% of 50KB/s"
else
    tap_fail "throughput accuracy" \
        "incomplete (${dl_bytes}/${FILE_BYTES} bytes) or zero elapsed"
fi
