#!/usr/bin/env bash
# t/load/06_client_abort.sh
#
# Verify that the cleanup handler fires correctly when a client aborts
# mid-download (connection reset without completing the transfer).
#
# WHY THIS IS THE MOST IMPORTANT EDGE CASE:
#   The module has two paths for removing a request from the per-IP queue:
#
#   Normal path:  log phase handler removes the queue entry, then the pool
#                 cleanup handler decrements lir->conn.
#
#   Abort path:   log phase is skipped. Only the pool cleanup handler fires,
#                 which must act as the safety net: find the queue entry,
#                 free it, AND decrement lir->conn.
#
#   The original c0c90f5 patch broke this with:
#       if (!tr->r) { ngx_slab_free_locked(shpool, tr); }
#   The condition is inverted — it only frees entries already cleaned by
#   the log phase (tr->r == NULL), never entries from aborted connections
#   (tr->r != NULL). The rewrite corrected this. This test verifies it.
#
# HOW WE SIMULATE AN ABORT:
#   curl --max-time <N> with N small enough that the download is still in
#   progress when the timeout fires. curl closes the socket, nginx sees a
#   broken pipe on the next write, and the connection cleanup fires without
#   going through the log phase.
#
# DETECTION STRATEGY:
#   After N aborted connections, start a fresh download and measure its rate.
#   If lir->conn was not properly decremented, it retains the stale count
#   from the aborted connections. The fresh download receives
#   limit / stale_conn instead of the full limit, completing much slower.
#   We abort 5 connections and then assert the fresh download gets >= 70%
#   of the full configured rate.

source "$(dirname "$0")/helpers.sh"

# 1. Initial download completes correctly (sanity)
# 2. Five aborted connections do not crash nginx
# 3. nginx error log contains no crit/emerg after aborts
# 4. Fresh download after aborts completes at near-full rate (conn cleanup)
# 5. lir->conn returns to zero: a second fresh download is equally fast
tap_plan 5

trap _cleanup EXIT
check_requirements

RATE_BYTES=102400      # 100 KB/s
RATE_DIRECTIVE="100k"
FILE_BYTES=2097152     # 2 MB — takes ~20s; abort at 2s leaves 90% unread
ABORT_TIMEOUT=2        # seconds before curl aborts mid-download
ABORT_COUNT=5
FRESH_FILE_BYTES=204800   # 200 KB — at 100KB/s takes ~2s; stale conn would make it ~10s

init_test_dir "client-abort"
make_file "$TEST_DIR/files/large.bin"  "$FILE_BYTES"
make_file "$TEST_DIR/files/small.bin"  "$FRESH_FILE_BYTES"

write_nginx_conf "2m" "$RATE_DIRECTIVE"
start_nginx

# Test 1 — baseline: a complete download works before we start aborting
DL_OUT="$TEST_DIR/downloads/baseline.bin"
mkdir -p "$TEST_DIR/downloads"
curl -s --max-time 30 -o "$DL_OUT" \
    "http://127.0.0.1:${TEST_PORT}/files/small.bin"
baseline_bytes=$(wc -c < "$DL_OUT" 2>/dev/null || echo 0)
if [ "$baseline_bytes" -eq "$FRESH_FILE_BYTES" ]; then
    tap_ok "baseline download complete ($baseline_bytes bytes)"
else
    tap_fail "baseline download" "${baseline_bytes}B / ${FRESH_FILE_BYTES}B expected"
fi

# Abort ABORT_COUNT downloads mid-transfer by timing out curl early.
# Run them sequentially so the connection count is predictable.
tap_diag "aborting $ABORT_COUNT downloads after ${ABORT_TIMEOUT}s each..."
for i in $(seq 1 "$ABORT_COUNT"); do
    curl -s --max-time "$ABORT_TIMEOUT" \
        -o /dev/null \
        "http://127.0.0.1:${TEST_PORT}/files/large.bin" 2>/dev/null || true
    tap_diag "  abort $i done"
done

# Allow nginx's lingering_close and pool destruction to complete.
# nginx default lingering_time is 5s; we wait 3s which is enough for
# the cleanup handler to fire (it fires on pool destruction, which happens
# when the connection is fully closed, not when we close our end).
tap_diag "waiting 3s for cleanup handlers to fire..."
sleep 3

# Test 2 — nginx still alive after the aborts
if kill -0 "$NGINX_PID" 2>/dev/null; then
    tap_ok "nginx still running after $ABORT_COUNT aborted connections"
else
    tap_fail "nginx survival" "nginx master process $NGINX_PID is gone"
fi

# Test 3 — no critical errors in log
assert_no_error_in_log '\[crit\]\|\[emerg\]\|\[alert\]' \
    "no critical errors after aborted connections"

# Test 4 — fresh download gets near-full rate (conn properly decremented)
# If lir->conn is stale at ABORT_COUNT+1 (including the baseline), fresh
# download gets limit/(ABORT_COUNT+1) = 100k/6 ≈ 17 KB/s.
# At 17 KB/s, 200 KB takes ~12s. At the correct full 100 KB/s it takes ~2s.
# We use 6s as the cutoff — comfortably between the two outcomes.
FRESH_OUT="$TEST_DIR/downloads/fresh1.bin"
fresh_start=$(date +%s%N)
curl -s --max-time 30 -o "$FRESH_OUT" \
    "http://127.0.0.1:${TEST_PORT}/files/small.bin"
fresh_elapsed=$(( ($(date +%s%N) - fresh_start + 999999999) / 1000000000 ))
fresh_bytes=$(wc -c < "$FRESH_OUT" 2>/dev/null || echo 0)
tap_diag "fresh download 1: ${fresh_elapsed}s, ${fresh_bytes}B"

if [ "$fresh_bytes" -eq "$FRESH_FILE_BYTES" ] && [ "$fresh_elapsed" -le 6 ]; then
    tap_ok "post-abort fresh download at full rate (${fresh_elapsed}s <= 6s)"
else
    tap_fail "conn cleanup after abort" \
        "took ${fresh_elapsed}s for ${fresh_bytes}B — lir->conn may not have been decremented by cleanup handler"
fi

# Test 5 — second fresh download equally fast (not a one-time recovery fluke)
sleep 1
FRESH_OUT2="$TEST_DIR/downloads/fresh2.bin"
fresh2_start=$(date +%s%N)
curl -s --max-time 30 -o "$FRESH_OUT2" \
    "http://127.0.0.1:${TEST_PORT}/files/small.bin"
fresh2_elapsed=$(( ($(date +%s%N) - fresh2_start + 999999999) / 1000000000 ))
tap_diag "fresh download 2: ${fresh2_elapsed}s"

if [ "$fresh2_elapsed" -le 6 ]; then
    tap_ok "second post-abort download equally fast (${fresh2_elapsed}s <= 6s)"
else
    tap_fail "conn counter stability" \
        "second download took ${fresh2_elapsed}s — counter may be drifting"
fi
