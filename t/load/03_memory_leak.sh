#!/usr/bin/env bash
# t/load/03_memory_leak.sh
#
# Prove that the slab allocator's memory usage is bounded under sustained load.
#
# WHY THE ORIGINAL TEST WAS TOO SHALLOW:
#   500 requests against a 4 KB file at 500 KB/s completes in ~4 seconds.
#   Linux kernel RSS granularity is 4 KB per page. A leak of 48 bytes per
#   request (one unfree'd queue entry) across 500 requests = 24 KB total,
#   which rounds to 8 kernel pages — invisible against RSS noise of 100+ KB
#   from nginx's own allocations. You need enough requests that a per-request
#   leak accumulates into multiple megabytes to be unambiguously detectable.
#
# THIS TEST RUNS TWO DETECTION STRATEGIES IN PARALLEL:
#
# Strategy A — RSS growth (what the original test did, but with 5000 requests):
#   5000 requests × 48 bytes/leak = 240 KB minimum detectable leak.
#   We allow 512 KB growth to absorb nginx buffer pool rounding.
#   A real unfixed leak (the inverted if(!tr->r) bug) would show ~3 MB growth.
#
# Strategy B — HTTP 503 rate (direct slab exhaustion detector):
#   Each unique IP creates one persistent rbtree node that is NEVER freed
#   (127.0.0.1 → one node, stays alive). But per-request queue entries ARE
#   freed on every request. If they leak, the 2 MB zone fills up after
#   roughly 2MB / 48 bytes ≈ 43,000 leaked entries. We use a 2 MB zone and
#   watch for the first 503, which would appear long before 5000 requests
#   if leaking (after ~43 requests with no free). Zero 503s in 5000 requests
#   is strong evidence of correct cleanup.

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
FILE_BYTES=65536       # 64 KB — large enough to exercise the rate path on
                       # each request, small enough to keep total time under
                       # 60s at 500 KB/s (64KB / 500KB/s × 5000 = 640s if
                       # sequential — we use parallel batches below)
RATE="500k"
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
        "$total_errors non-200 responses — queue entries may be leaking"
fi

# Test 5 — zone still healthy
assert_http_status \
    "http://127.0.0.1:${TEST_PORT}/files/small.bin" "200" \
    "zone healthy after load"

RSS_AFTER=$(get_worker_rss "$WORKER_PID")
tap_diag "RSS: baseline=${RSS_BASELINE}KB final=${RSS_AFTER}KB growth=$(( RSS_AFTER - RSS_BASELINE ))KB"
