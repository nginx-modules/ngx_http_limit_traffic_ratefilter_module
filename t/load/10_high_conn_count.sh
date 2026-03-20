#!/usr/bin/env bash
# t/load/10_high_conn_count.sh
#
# Verify correct arithmetic when a large number of connections from one IP
# share a rate bucket simultaneously.
#
# WHY THIS IS AN EDGE CASE:
#   lir->conn is declared as u_short (maximum 65535). When many connections
#   are active at once, two arithmetic properties of the module are stressed:
#
#   1. Per-connection rate: r->limit_rate = limit / conn
#      With conn=50 and limit=500KB/s, each gets 10KB/s.
#      With conn=100 and limit=100KB/s, each gets 1KB/s — still valid.
#      With conn=500 and limit=100KB/s, each gets 204 bytes/sec — very slow
#      but must not produce zero (division result rounds down in integer math;
#      a 100KB/s limit with 65536 connections gives 1 byte/sec, not 0).
#
#   2. Cleanup ordering: 50 connections closing near-simultaneously means
#      50 cleanup handlers fire in quick succession. Each decrements conn.
#      The final decrement must bring conn to exactly zero, triggering
#      rbtree node deletion. If any decrement is skipped (e.g. due to the
#      abort-path bug), conn stays positive and the node leaks permanently.
#
# STRATEGY:
#   Open 50 parallel curl connections simultaneously. Each downloads the
#   same file. Measure aggregate throughput and verify the node is properly
#   cleaned up (fresh single download returns to full rate) after all close.

source "$(dirname "$0")/helpers.sh"

# 1. 50 simultaneous connections all receive HTTP 200
# 2. Aggregate throughput within ±40% of configured limit
# 3. Per-connection rate is correctly divided (no connection gets full limit)
# 4. After all close, conn returns to zero (fresh download at full rate)
# 5. No critical errors in log
tap_plan 5

trap _cleanup EXIT
check_requirements

RATE_BYTES=512000      # 500 KB/s total
RATE_DIRECTIVE="500k"
FILE_BYTES=204800      # 200 KB per connection
NUM_CONN=50
TOTAL_BYTES=$(( FILE_BYTES * NUM_CONN ))

# Per-connection rate = 500KB/s / 50 = 10KB/s
# 200KB at 10KB/s = 20s expected
# If rate is NOT divided (each gets full 500KB/s), 200KB takes ~0.4s
# Lower bound of 10s comfortably distinguishes the two cases
EXPECTED_LOWER=10

init_test_dir "high-conn"
make_file "$TEST_DIR/files/shared.bin" "$FILE_BYTES"
make_file "$TEST_DIR/files/probe.bin" 51200   # 50 KB for fresh-rate probe

write_nginx_conf "4m" "$RATE_DIRECTIVE"
start_nginx

# Launch NUM_CONN parallel curl downloads of the same file.
tap_diag "launching $NUM_CONN simultaneous connections..."
OUT_DIR="$TEST_DIR/downloads"
mkdir -p "$OUT_DIR"
pids=()
t_start=$(date +%s%N)

for i in $(seq 1 "$NUM_CONN"); do
    curl -s --max-time 60 \
        -o "${OUT_DIR}/conn-${i}.bin" \
        "http://127.0.0.1:${TEST_PORT}/files/shared.bin" &
    pids+=($!)
done

failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=$(( failed + 1 )); done
elapsed=$(( ($(date +%s%N) - t_start + 999999999) / 1000000000 ))
tap_diag "$NUM_CONN connections done: ${elapsed}s, ${failed} failed"

# Count successful (complete) downloads.
complete=0
for i in $(seq 1 "$NUM_CONN"); do
    b=$(wc -c < "${OUT_DIR}/conn-${i}.bin" 2>/dev/null || echo 0)
    if [ "$b" -eq "$FILE_BYTES" ]; then complete=$(( complete + 1 )); fi
done
tap_diag "complete downloads: ${complete}/${NUM_CONN}"

# Test 1 — all (or nearly all) connections received HTTP 200 and full file
if [ "$complete" -ge $(( NUM_CONN * 9 / 10 )) ]; then
    tap_ok "$complete/$NUM_CONN connections delivered complete files"
else
    tap_fail "high-conn delivery" \
        "only $complete/$NUM_CONN complete — too many connections may have failed"
fi

# Test 2 — aggregate throughput within ±40% of configured limit
actual_bytes=$(( complete * FILE_BYTES ))
if [ "$elapsed" -gt 0 ] && [ "$actual_bytes" -gt 0 ]; then
    assert_rate_within_bounds \
        "$actual_bytes" "$elapsed" "$RATE_BYTES" 40 \
        "aggregate throughput within ±40% of 500KB/s with $NUM_CONN connections"
else
    tap_fail "aggregate throughput" "elapsed=${elapsed}s bytes=${actual_bytes}"
fi

# Test 3 — rate WAS divided: each connection did not get the full rate.
# If the limit were not divided, 200KB per connection would complete in
# ~0.4s, and all NUM_CONN connections would finish in ~0.4s total.
# We assert the total took at least EXPECTED_LOWER seconds.
if [ "$elapsed" -ge "$EXPECTED_LOWER" ]; then
    tap_ok "rate correctly divided: total ${elapsed}s >= ${EXPECTED_LOWER}s"
else
    tap_fail "rate division check" \
        "${elapsed}s < ${EXPECTED_LOWER}s — each connection may have gotten the full limit"
fi

# Test 4 — conn returns to zero after all connections close.
# At full 500KB/s, 50KB takes ~0.1s. If conn is stale at 50, probe gets
# 500k/50 = 10KB/s and takes ~5s. We allow 3s as the cutoff.
sleep 2
PROBE_OUT="$TEST_DIR/downloads/probe.bin"
probe_start=$(date +%s%N)
curl -s --max-time 15 -o "$PROBE_OUT" \
    "http://127.0.0.1:${TEST_PORT}/files/probe.bin"
probe_elapsed=$(( ($(date +%s%N) - probe_start + 999999999) / 1000000000 ))
probe_bytes=$(wc -c < "$PROBE_OUT" 2>/dev/null || echo 0)
tap_diag "post-storm probe: ${probe_bytes}B in ${probe_elapsed}s"

if [ "$probe_bytes" -eq 51200 ] && [ "$probe_elapsed" -le 3 ]; then
    tap_ok "conn zeroed after $NUM_CONN connections (probe ${probe_elapsed}s <= 3s)"
else
    tap_fail "conn cleanup after high load" \
        "probe ${probe_elapsed}s for ${probe_bytes}B — lir->conn may be stale"
fi

# Test 5
assert_no_error_in_log '\[crit\]\|\[emerg\]' \
    "no critical errors with $NUM_CONN simultaneous connections"
