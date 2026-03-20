#!/usr/bin/env bash
# t/load/04_reload_safety.sh
#
# Prove that nginx -s reload (SIGHUP) does not corrupt or stall an
# in-progress download. A large file is downloaded at a limited rate while
# two successive reloads fire mid-transfer.

source "$(dirname "$0")/helpers.sh"

# 1. Download completes successfully after two reloads
# 2. Downloaded file is byte-for-byte identical to the source
# 3. New worker responds to requests after reload
# 4. No [crit]/[emerg] in error log
# 5. Worker PID changed (reload actually happened)
tap_plan 5

trap _cleanup EXIT
check_requirements

RATE_DIRECTIVE="100k"
FILE_BYTES=2097152     # 2 MB at 100 KB/s → ~20s; enough time for two reloads
RELOAD_DELAY_1=3
RELOAD_DELAY_2=6
DOWNLOAD_TIMEOUT=60

init_test_dir "reload-safety"
make_file "$TEST_DIR/files/largefile.bin" "$FILE_BYTES"
write_nginx_conf "2m" "$RATE_DIRECTIVE"
start_nginx

MASTER_PID="$NGINX_PID"
INITIAL_WORKER=$(get_worker_pids | head -1)
tap_diag "master: $MASTER_PID  initial worker: $INITIAL_WORKER"

# Start the download in the background.
DL_OUT="$TEST_DIR/downloads/largefile.bin"
mkdir -p "$TEST_DIR/downloads"
curl -s --max-time "$DOWNLOAD_TIMEOUT" \
    -o "$DL_OUT" \
    "http://127.0.0.1:${TEST_PORT}/files/largefile.bin" &
CURL_PID=$!
tap_diag "curl download started (pid=$CURL_PID)"

# Fire two reloads from a subshell while the download is in progress.
(
    sleep $RELOAD_DELAY_1
    kill -HUP "$MASTER_PID" 2>/dev/null && tap_diag "first reload sent (t=${RELOAD_DELAY_1}s)"
    sleep $(( RELOAD_DELAY_2 - RELOAD_DELAY_1 ))
    kill -HUP "$MASTER_PID" 2>/dev/null && tap_diag "second reload sent (t=${RELOAD_DELAY_2}s)"
) &
RELOAD_PID=$!

# Wait for curl using a deadline loop in the shell that owns the PID.
download_status=0
deadline=$(( $(date +%s) + DOWNLOAD_TIMEOUT ))
while kill -0 "$CURL_PID" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        tap_diag "download timed out after ${DOWNLOAD_TIMEOUT}s"
        kill -TERM "$CURL_PID" 2>/dev/null || true
        download_status=124
        break
    fi
    sleep 1
done
[ "$download_status" -ne 124 ] \
    && { wait "$CURL_PID" 2>/dev/null && download_status=0 || download_status=$?; }

wait "$RELOAD_PID" 2>/dev/null || true
tap_diag "download finished (status=$download_status)"
sleep 2

# Test 1
if [ "$download_status" -eq 0 ]; then
    tap_ok "download completed after two hot reloads"
else
    tap_fail "download completion" "curl exited with status $download_status"
fi

# Test 2
if [ -f "$DL_OUT" ] \
    && [ "$(wc -c < "$DL_OUT")" -eq "$FILE_BYTES" ] \
    && cmp -s "$TEST_DIR/files/largefile.bin" "$DL_OUT"; then
    tap_ok "downloaded file complete and byte-identical"
else
    tap_fail "file integrity" \
        "got $(wc -c < "$DL_OUT" 2>/dev/null || echo 0)B, expected ${FILE_BYTES}B"
fi

# Test 3
assert_http_status \
    "http://127.0.0.1:${TEST_PORT}/files/largefile.bin" "200" \
    "new worker serves from shared zone post-reload"

# Test 4
assert_no_error_in_log '\[crit\]\|\[emerg\]\|\[alert\]' \
    "no critical log entries during reload"

# Test 5
FINAL_WORKER=$(get_worker_pids | head -1)
tap_diag "initial worker: $INITIAL_WORKER  final worker: $FINAL_WORKER"
if [ -n "$FINAL_WORKER" ] && [ "$FINAL_WORKER" != "$INITIAL_WORKER" ]; then
    tap_ok "worker PID changed ($INITIAL_WORKER → $FINAL_WORKER): reload confirmed"
else
    tap_fail "reload confirmation" "worker PID unchanged"
fi
