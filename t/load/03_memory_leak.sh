#!/usr/bin/env bash
# t/load/03_memory_leak.sh
#
# Regression checks for memory growth and successful cleanup under 5,000
# requests. The current implementation allocates one shared tree node per
# active key and frees it when the last request finishes; it no longer has
# per-request queue entries in the shared slab. Worker RSS is only a coarse
# signal and must not be presented as proof of leak freedom.
#
source "$(dirname "$0")/helpers.sh"

# 1. nginx starts and serves requests
# 2. No non-200 responses during 500-request warm-up
# 3. RSS growth <= 512 KB across 4500 stress requests
# 4. Zero HTTP 503s across all 5000 requests (no slab exhaustion)
# 5. Zone still healthy after all requests
tap_plan 5

trap _cleanup EXIT
check_requirements

WARMUP_REQUESTS=500
STRESS_REQUESTS=4500
FILE_BYTES=65536       # 64 KiB * 5,000 requests ~= 312.5 MiB in total.
                       # This is a cleanup test, not a throughput benchmark.
                       # Use a high per-key rate so it finishes within CI's
                       # 300-second per-test deadline after rate enforcement.
RATE="32m"
MAX_RSS_GROWTH_KB=512

init_test_dir "memory-leak"
make_file "$TEST_DIR/files/small.bin" "$FILE_BYTES"
write_nginx_conf "2m" "$RATE"
start_nginx

# Test 1
assert_http_status \
    "http://127.0.0.1:${TEST_PORT}/files/small.bin" "200" \
    "nginx serves file before load"

# Worker PID for RSS tracking
WORKER_PID=""
for _ in $(seq 1 20); do
    WORKER_PID=$(get_worker_pids | head -1)
    if [ -n "$WORKER_PID" ]; then break; fi
    sleep 0.2
done
if [ -z "$WORKER_PID" ]; then
    tap_bail_out "could not find nginx worker (master=$NGINX_PID)"
fi
tap_diag "tracking worker pid: $WORKER_PID"

# run_requests_parallel <count> <label>
# Sends requests in batches of 20 concurrent curl processes.
# All diagnostic output goes to stderr; only the non-200 count to stdout.
run_requests_parallel() {
    local count="$1" label="$2" concurrency=20
    local codes_file; codes_file=$(mktemp)
    local dispatched=0 pids=()

    while [ "$dispatched" -lt "$count" ]; do
        local batch=$(( count - dispatched ))
        if [ "$batch" -gt "$concurrency" ]; then batch=$concurrency; fi

        pids=()
        local i
        for i in $(seq 1 "$batch"); do
            curl -s -o /dev/null -w '%{http_code}\n' \
                --max-time 10 \
                "http://127.0.0.1:${TEST_PORT}/files/small.bin" \
                >> "$codes_file" 2>/dev/null &
            pids+=($!)
        done
        for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
        dispatched=$(( dispatched + batch ))
    done

    local non200
    non200=$(grep -c -v '^200$' "$codes_file" 2>/dev/null || true)
    non200="${non200:-0}"
    echo "# ${label}: ${count} requests, non-200: ${non200}" >&2
    rm -f "$codes_file"
    echo "$non200"
}

# Test 2 — warm-up phase
tap_diag "warm-up: $WARMUP_REQUESTS requests (parallel)..."
warmup_errors=$(run_requests_parallel "$WARMUP_REQUESTS" "warm-up")
if [ "$warmup_errors" -eq 0 ]; then
    tap_ok "warm-up: all $WARMUP_REQUESTS requests returned HTTP 200"
else
    tap_fail "warm-up health" "$warmup_errors non-200 in warm-up"
fi

sleep 0.5
RSS_BASELINE=$(get_worker_rss "$WORKER_PID")
tap_diag "RSS baseline: ${RSS_BASELINE}KB"

# Test 3 — stress phase, measure RSS growth
tap_diag "stress: $STRESS_REQUESTS requests (parallel)..."
stress_errors=$(run_requests_parallel "$STRESS_REQUESTS" "stress")

sleep 1
assert_rss_growth_bounded "$WORKER_PID" "$RSS_BASELINE" "$MAX_RSS_GROWTH_KB" \
    "RSS growth <= ${MAX_RSS_GROWTH_KB}KB over $STRESS_REQUESTS requests"

# Test 4 — zero 503s across both phases (slab never exhausted)
total_errors=$(( warmup_errors + stress_errors ))
if [ "$total_errors" -eq 0 ]; then
    tap_ok "zero non-200 across all $(( WARMUP_REQUESTS + STRESS_REQUESTS )) requests"
else
    tap_fail "no slab exhaustion" \
        "$total_errors non-200 responses — possible memory or request failure"
fi

# Test 5 — zone still healthy
assert_http_status \
    "http://127.0.0.1:${TEST_PORT}/files/small.bin" "200" \
    "zone healthy after load"

RSS_AFTER=$(get_worker_rss "$WORKER_PID")
tap_diag "RSS: baseline=${RSS_BASELINE}KB final=${RSS_AFTER}KB growth=$(( RSS_AFTER - RSS_BASELINE ))KB"
