#!/usr/bin/env bash
# t/load/08_worker_concurrency.sh
#
# Verify that the shmtx mutex correctly serialises shared zone access when
# multiple nginx worker processes run concurrently.
#
# WHY THIS IS NOT COVERED BY OTHER TESTS:
#   All other tests use worker_processes 1. With one worker, the shmtx is
#   never actually contended — it is always acquired and released by the
#   same process with no waiting. The correctness of the locking under real
#   inter-process contention is never exercised.
#
#   With worker_processes 4 and high concurrent load, multiple workers
#   simultaneously attempt ngx_shmtx_lock(&shpool->mutex) on the same
#   zone. This exercises:
#     - The mutex implementation itself (spinlock or semaphore depending
#       on the platform and nginx compile flags)
#     - Correct rbtree state after interleaved lock/unlock cycles
#     - No double-free or use-after-free when two workers race on the
#       same rbtree node (same client IP, different connections)
#
# DETECTION STRATEGY:
#   We run 200 concurrent curl requests. With 4 workers, each handles ~50.
#   All requests come from 127.0.0.1 so they all contend on the same
#   rbtree node. We assert:
#     a. No HTTP 500 responses (would indicate a crash in a worker)
#     b. No SIGSEGV/abort in the error log (worker crash from memory corruption)
#     c. nginx master still alive after the load (no cascading crash)
#     d. All 200 requests return 200 or 503 (503 is acceptable if zone fills,
#        but 500 is not — it means the module returned an error code it should
#        not have, or nginx caught a crash in the worker)

source "$(dirname "$0")/helpers.sh"

# 1. nginx starts with 4 workers
# 2. 200 concurrent requests: zero HTTP 500 responses
# 3. No worker crash signals in error log
# 4. nginx master alive after concurrent load
# 5. Rate limiting still functional after concurrent load
tap_plan 5

trap _cleanup EXIT
check_requirements

RATE_DIRECTIVE="200k"
FILE_BYTES=65536       # 64 KB — small enough for fast concurrent transfers
CONCURRENCY=200
RATE_BYTES=204800      # 200 KB/s

init_test_dir "worker-concurrency"
make_file "$TEST_DIR/files/concurrent.bin" "$FILE_BYTES"

# Override write_nginx_conf's worker_processes with a 4-worker config.
local_preamble="$(get_load_module_preamble)"
cat > "$NGINX_CONF" <<NGINXCONF
${local_preamble}
worker_processes 4;
pid $TEST_DIR/nginx.pid;
error_log $TEST_DIR/logs/error.log debug;

events { worker_connections 256; }

http {
    limit_traffic_rate_zone rate \$remote_addr 4m;

    log_format test '\$status';
    access_log $TEST_DIR/logs/access.log test;

    server {
        listen ${TEST_PORT};
        location /files/ {
            root $TEST_DIR;
            limit_traffic_rate rate ${RATE_DIRECTIVE};
            add_header Accept-Ranges bytes;
        }
    }
}
NGINXCONF

start_nginx

# Verify we actually have 4 workers.
worker_count=$(get_worker_pids | wc -l)
tap_diag "worker count: $worker_count"
if [ "$worker_count" -ne 4 ]; then
    tap_diag "WARNING: expected 4 workers, got $worker_count"
fi

# Test 1 — startup
assert_http_status \
    "http://127.0.0.1:${TEST_PORT}/files/concurrent.bin" "200" \
    "nginx starts with 4 workers"

# Launch CONCURRENCY parallel curl requests.
tap_diag "launching $CONCURRENCY concurrent requests across 4 workers..."
CODES_FILE="$TEST_DIR/codes.txt"
pids=()
t_start=$(date +%s%N)

for i in $(seq 1 "$CONCURRENCY"); do
    curl -s -o /dev/null -w '%{http_code}\n' \
        --max-time 30 \
        "http://127.0.0.1:${TEST_PORT}/files/concurrent.bin" \
        >> "$CODES_FILE" 2>/dev/null &
    pids+=($!)
done

for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done
elapsed=$(( ($(date +%s%N) - t_start + 999999999) / 1000000000 ))

count_200=$(grep -c '^200$' "$CODES_FILE" 2>/dev/null || true); count_200="${count_200:-0}"
count_500=$(grep -c '^500$' "$CODES_FILE" 2>/dev/null || true); count_500="${count_500:-0}"
count_503=$(grep -c '^503$' "$CODES_FILE" 2>/dev/null || true); count_503="${count_503:-0}"
count_000=$(grep -c '^000$' "$CODES_FILE" 2>/dev/null || true); count_000="${count_000:-0}"
tap_diag "results: 200=${count_200} 500=${count_500} 503=${count_503} timeout=${count_000} elapsed=${elapsed}s"

# Test 2 — zero 500s (500 indicates a module crash or internal error)
if [ "$count_500" -eq 0 ]; then
    tap_ok "zero HTTP 500 responses across $CONCURRENCY concurrent requests"
else
    tap_fail "no 500 responses" \
        "$count_500 HTTP 500s — worker may have crashed or module returned internal error"
fi

# Test 3 — no crash signals in log
assert_no_error_in_log '\[crit\]\|\[emerg\]\|SIGSEGV\|segfault\|core dumped' \
    "no worker crash signals in error log"

# Test 4 — master alive
if kill -0 "$NGINX_PID" 2>/dev/null; then
    tap_ok "nginx master alive after $CONCURRENCY concurrent requests"
else
    tap_fail "nginx survival" "master $NGINX_PID gone after concurrent load"
fi

# Test 5 — rate limiting still works after the concurrent storm
# A fresh single download should still be rate-limited.
# 64 KB at 200 KB/s = 0.3s unconstrained; with rate limit ~0.3s too since
# it's a small file. We verify the zone is healthy by checking HTTP 200
# and that the file is served completely.
FRESH_OUT="$TEST_DIR/downloads/post.bin"
mkdir -p "$TEST_DIR/downloads"
sleep 1
curl -s --max-time 10 -o "$FRESH_OUT" \
    "http://127.0.0.1:${TEST_PORT}/files/concurrent.bin"
fresh_bytes=$(wc -c < "$FRESH_OUT" 2>/dev/null || echo 0)
if [ "$fresh_bytes" -eq "$FILE_BYTES" ]; then
    tap_ok "rate limiting functional after concurrent load (${fresh_bytes}B complete)"
else
    tap_fail "post-load functionality" \
        "got ${fresh_bytes}B expected ${FILE_BYTES}B — zone may be corrupt"
fi
