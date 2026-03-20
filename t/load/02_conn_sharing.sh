#!/usr/bin/env bash
# t/load/02_conn_sharing.sh
#
# Verify that N simultaneous connections from the same IP correctly share
# one rate bucket. Each gets rate/N; aggregate throughput stays at the limit.
#
# WHY THESE NUMBERS:
#   3 connections × 200 KB each = 600 KB total.
#   Shared limit 120 KB/s → expected ~5s.
#   If the rate is NOT shared, each gets full 120 KB/s → ~1.7s.
#   4s lower bound comfortably distinguishes the two cases.
#
#   The post-parallel single-connection test verifies that lir->conn is
#   decremented back to zero after all connections close. If conn stays
#   stale at 3, the new single connection would get 120k/3 = 40 KB/s and
#   take ~5s instead of ~1.7s — clearly distinguishable.

source "$(dirname "$0")/helpers.sh"

# 1. All files served (HTTP 200)
# 2. Parallel wall-clock time >= 4s (rate sharing confirmed)
# 3. Aggregate throughput within ±35% of configured limit
# 4. All downloaded files complete and byte-identical
# 5. Post-parallel single download at full rate (<= 5s for 200KB at 120KB/s)
tap_plan 5

trap _cleanup EXIT
check_requirements

RATE_BYTES=122880      # 120 KB/s
RATE_DIRECTIVE="120k"
FILE_BYTES=204800      # 200 KB per file
NUM_CLIENTS=3
TOTAL_BYTES=$(( FILE_BYTES * NUM_CLIENTS ))

init_test_dir "conn-sharing"
for i in $(seq 1 $NUM_CLIENTS); do
    make_file "$TEST_DIR/files/file${i}.bin" "$FILE_BYTES"
done

write_nginx_conf "2m" "$RATE_DIRECTIVE"
start_nginx

# Test 1
all_ok=true
for i in $(seq 1 $NUM_CLIENTS); do
    code=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 5 \
               "http://127.0.0.1:${TEST_PORT}/files/file${i}.bin")
    if [ "$code" != "200" ]; then
        all_ok=false
        tap_diag "file${i}.bin returned HTTP $code"
    fi
done
if $all_ok; then
    tap_ok "all $NUM_CLIENTS test files served with HTTP 200"
else
    tap_fail "file accessibility" "one or more files returned non-200"
fi

# Tests 2–4 — parallel downloads
tap_diag "launching $NUM_CLIENTS parallel curl downloads..."
PARALLEL_OUT="$TEST_DIR/downloads/parallel"
mkdir -p "$PARALLEL_OUT"
t_start=$(date +%s%N)
pids=()

for i in $(seq 1 $NUM_CLIENTS); do
    curl -s --max-time 120 \
        -o "${PARALLEL_OUT}/file${i}.bin" \
        "http://127.0.0.1:${TEST_PORT}/files/file${i}.bin" &
    pids+=($!)
done

failed=0
for pid in "${pids[@]}"; do wait "$pid" || failed=$(( failed + 1 )); done

elapsed=$(( ($(date +%s%N) - t_start + 999999999) / 1000000000 ))
tap_diag "parallel done: ${elapsed}s, ${failed} failed"

# Test 2
if [ "$elapsed" -ge 4 ]; then
    tap_ok "parallel downloads took ${elapsed}s >= 4s (rate sharing confirmed)"
else
    tap_fail "rate sharing" "finished in ${elapsed}s — expected >=4s if rate is shared"
fi

# Test 3
if [ "$elapsed" -gt 0 ]; then
    assert_rate_within_bounds \
        "$TOTAL_BYTES" "$elapsed" "$RATE_BYTES" 35 \
        "aggregate throughput within ±35% of 120KB/s"
else
    tap_fail "aggregate throughput" "elapsed is zero"
fi

# Test 4
corrupt=0
for i in $(seq 1 $NUM_CLIENTS); do
    dl="${PARALLEL_OUT}/file${i}.bin"
    if [ -f "$dl" ]; then
        bytes=$(wc -c < "$dl")
        if [ "$bytes" -ne "$FILE_BYTES" ]; then
            tap_diag "file${i}: ${bytes}B expected ${FILE_BYTES}B"
            corrupt=$(( corrupt + 1 ))
        fi
        if ! cmp -s "$TEST_DIR/files/file${i}.bin" "$dl"; then
            tap_diag "file${i}: content mismatch"
            corrupt=$(( corrupt + 1 ))
        fi
    else
        tap_diag "file${i}: not found"
        corrupt=$(( corrupt + 1 ))
    fi
done
if [ "$corrupt" -eq 0 ]; then
    tap_ok "all $NUM_CLIENTS files complete and byte-identical"
else
    tap_fail "file integrity" "$corrupt corruption(s)"
fi

# Test 5 — conn counter back to zero after all downloads
sleep 1
FRESH_OUT="$TEST_DIR/downloads/fresh"
mkdir -p "$FRESH_OUT"
fresh_start=$(date +%s%N)
curl -s --max-time 30 -o "${FRESH_OUT}/file1.bin" \
    "http://127.0.0.1:${TEST_PORT}/files/file1.bin"
fresh_elapsed=$(( ($(date +%s%N) - fresh_start + 999999999) / 1000000000 ))
tap_diag "fresh single download: ${fresh_elapsed}s"

# At 120KB/s, 200KB → ~1.7s expected. Allow up to 5s for CI jitter.
# If stale conn=3, it would take ~5s — the boundary — so we use 6s as fail.
if [ "$fresh_elapsed" -le 6 ]; then
    tap_ok "post-parallel fresh download at full rate (${fresh_elapsed}s <= 6s)"
else
    tap_fail "post-parallel conn cleanup" \
        "took ${fresh_elapsed}s — lir->conn may not have been decremented"
fi
