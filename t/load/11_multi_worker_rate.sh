#!/usr/bin/env bash
# Verify aggregate rate division under simultaneous connections on 4 workers.
# The single-worker throughput test cannot exercise cross-worker sharing.

source "$(dirname "$0")/helpers.sh"

tap_plan 5
trap _cleanup EXIT
check_requirements

LIMIT=204800               # 200 KiB/s per remote_addr bucket
CLIENTS=8
BYTES_PER_CLIENT=262144  # 256 KiB each, ~10 s aggregate at the limit
TOTAL_BYTES=$((CLIENTS * BYTES_PER_CLIENT))

init_test_dir "multi-worker-rate"
make_file "$TEST_DIR/files/shared.bin" "$BYTES_PER_CLIENT"
TEST_NGINX_WORKERS=4 write_nginx_conf "2m" "200k"
start_nginx

workers=$(get_worker_pids | wc -l)
if [ "$workers" -eq 4 ]; then
    tap_ok "four nginx workers started"
else
    tap_fail "four workers" "expected 4, got $workers"
fi

pids=()
for i in $(seq 1 "$CLIENTS"); do
    : > "$TEST_DIR/downloads/status-$i"
done

start=$(date +%s%N)
for i in $(seq 1 "$CLIENTS"); do
    curl -fsS --max-time 50 \
        -o "$TEST_DIR/downloads/file-$i" \
        -w '%{http_code}\n' \
        "http://127.0.0.1:${TEST_PORT}/files/shared.bin" \
        > "$TEST_DIR/downloads/status-$i" &
    pids+=("$!")
done

failures=0
for pid in "${pids[@]}"; do
    wait "$pid" || failures=$((failures + 1))
done
elapsed=$(( ($(date +%s%N) - start + 999999999) / 1000000000 ))
tap_diag "concurrent requests elapsed=${elapsed}s failures=${failures}"

status_errors=0
for i in $(seq 1 "$CLIENTS"); do
    [ "$(cat "$TEST_DIR/downloads/status-$i")" = "200" ] || status_errors=$((status_errors + 1))
done
if [ "$failures" -eq 0 ] && [ "$status_errors" -eq 0 ]; then
    tap_ok "all $CLIENTS requests completed with HTTP 200"
else
    tap_fail "concurrent HTTP responses" "curl failures=$failures, invalid statuses=$status_errors"
fi

corrupt=0
for i in $(seq 1 "$CLIENTS"); do
    cmp -s "$TEST_DIR/files/shared.bin" "$TEST_DIR/downloads/file-$i" \
        || corrupt=$((corrupt + 1))
done
if [ "$corrupt" -eq 0 ]; then
    tap_ok "all concurrent downloads are byte-identical"
else
    tap_fail "concurrent download integrity" "$corrupt corrupt or incomplete"
fi

if [ "$elapsed" -ge 6 ] && [ "$elapsed" -le 30 ]; then
    tap_ok "aggregate throttle effective ($elapsed seconds for $TOTAL_BYTES bytes)"
else
    tap_fail "aggregate throttle" "expected 6..30 seconds, got $elapsed"
fi

assert_no_error_in_log '\[crit\]\|\[emerg\]\|SIGSEGV\|segfault' \
    "no critical errors or worker crashes"
