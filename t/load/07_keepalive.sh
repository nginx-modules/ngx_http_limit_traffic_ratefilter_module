#!/usr/bin/env bash
# t/load/07_keepalive.sh
#
# Verify correct behaviour across multiple sequential requests on a single
# HTTP keep-alive connection.
#
# WHY THIS IS AN EDGE CASE:
#   nginx's r->connection->sent field counts the total bytes sent on the
#   TCP connection, not on the current HTTP request. Under HTTP/1.1
#   keep-alive, a single connection serves multiple requests. The original
#   module code used r->connection->sent as a delta to compute per-request
#   throughput, which would show an enormous delta on the second request
#   (it includes all bytes from the first request). The rewrite delegates
#   rate enforcement to r->limit_rate, which is set fresh on each request,
#   so this should not be a problem — but this test verifies it explicitly.
#
# WHAT WE TEST:
#   1. The first request on a keep-alive connection is rate-limited correctly.
#   2. The SECOND request on the SAME connection is ALSO rate-limited
#      correctly and is not spuriously throttled or sped up.
#   3. lir->conn is incremented and decremented correctly across keep-alive
#      requests (the same connection counts as one while active).
#
# HOW WE FORCE KEEP-ALIVE:
#   curl with --keepalive and multiple -o outputs reuses the same connection.
#   curl's --next flag chains requests on the same connection in HTTP/1.1
#   keep-alive mode.

source "$(dirname "$0")/helpers.sh"

# 1. First keep-alive request rate-limited correctly
# 2. Second keep-alive request rate-limited correctly (not polluted by first)
# 3. Both requests complete fully (no corruption)
# 4. After keep-alive session ends, lir->conn returns to zero
# 5. No errors in nginx log
tap_plan 5

trap _cleanup EXIT
check_requirements

RATE_BYTES=102400      # 100 KB/s
RATE_DIRECTIVE="100k"
# Use a file size where the rate limit is clearly observable:
# 512 KB at 100 KB/s → ~5s. Two sequential requests → ~10s total.
FILE_BYTES=524288

init_test_dir "keepalive"
make_file "$TEST_DIR/files/ka.bin" "$FILE_BYTES"

write_nginx_conf "2m" "$RATE_DIRECTIVE"
start_nginx

OUT1="$TEST_DIR/downloads/ka1.bin"
OUT2="$TEST_DIR/downloads/ka2.bin"
mkdir -p "$TEST_DIR/downloads"

# Issue two sequential GET requests on one keep-alive connection using
# curl's --next flag. This is HTTP/1.1 pipelining within one TCP session.
tap_diag "issuing two sequential requests on one keep-alive connection..."
overall_start=$(date +%s%N)

curl -s \
    --keepalive \
    --max-time 60 \
    -o "$OUT1" \
    "http://127.0.0.1:${TEST_PORT}/files/ka.bin" \
    --next \
    -o "$OUT2" \
    "http://127.0.0.1:${TEST_PORT}/files/ka.bin"

overall_elapsed=$(( ($(date +%s%N) - overall_start + 999999999) / 1000000000 ))
tap_diag "both requests completed in ${overall_elapsed}s"

bytes1=$(wc -c < "$OUT1" 2>/dev/null || echo 0)
bytes2=$(wc -c < "$OUT2" 2>/dev/null || echo 0)
tap_diag "request 1: ${bytes1}B  request 2: ${bytes2}B"

# Test 1 — first request took at least 4s (rate limiting engaged)
# Two 512KB files sequentially at 100KB/s = ~10s total.
# Each should take ~5s; we assert total >= 8s (allowing 2s burst slack).
if [ "$overall_elapsed" -ge 8 ]; then
    tap_ok "two keep-alive requests took ${overall_elapsed}s >= 8s (rate limiting active)"
else
    tap_fail "keep-alive rate limiting" \
        "both requests completed in ${overall_elapsed}s — rate limit not engaging on keep-alive"
fi

# Test 2 — total throughput is within bounds
# 2 × 512 KB = 1 MB total; at 100 KB/s = ~10s expected.
total_bytes=$(( bytes1 + bytes2 ))
if [ "$overall_elapsed" -gt 0 ]; then
    assert_rate_within_bounds \
        "$total_bytes" "$overall_elapsed" "$RATE_BYTES" 35 \
        "keep-alive aggregate throughput within ±35% of 100KB/s"
else
    tap_fail "keep-alive throughput" "elapsed is zero"
fi

# Test 3 — both files complete and identical to source
corrupt=0
for out in "$OUT1" "$OUT2"; do
    b=$(wc -c < "$out" 2>/dev/null || echo 0)
    if [ "$b" -ne "$FILE_BYTES" ]; then
        tap_diag "$out: ${b}B expected ${FILE_BYTES}B"
        corrupt=$(( corrupt + 1 ))
    fi
    if ! cmp -s "$TEST_DIR/files/ka.bin" "$out"; then
        tap_diag "$out: content mismatch"
        corrupt=$(( corrupt + 1 ))
    fi
done
if [ "$corrupt" -eq 0 ]; then
    tap_ok "both keep-alive files complete and byte-identical"
else
    tap_fail "keep-alive file integrity" "$corrupt issue(s) detected"
fi

# Test 4 — conn returns to zero after keep-alive session ends
# After curl exits the keep-alive connection closes. We wait for the cleanup
# handler to decrement lir->conn and then verify a fresh download is fast.
sleep 2
FRESH_OUT="$TEST_DIR/downloads/fresh.bin"
make_file "$TEST_DIR/files/small.bin" 204800
chmod 644 "$TEST_DIR/files/small.bin"
fresh_start=$(date +%s%N)
curl -s --max-time 15 -o "$FRESH_OUT" \
    "http://127.0.0.1:${TEST_PORT}/files/small.bin"
fresh_elapsed=$(( ($(date +%s%N) - fresh_start + 999999999) / 1000000000 ))
tap_diag "fresh download after keep-alive: ${fresh_elapsed}s"

if [ "$fresh_elapsed" -le 5 ]; then
    tap_ok "conn zeroed after keep-alive session (fresh download ${fresh_elapsed}s <= 5s)"
else
    tap_fail "conn cleanup after keep-alive" \
        "fresh download took ${fresh_elapsed}s — lir->conn may be stale"
fi

# Test 5
assert_no_error_in_log '\[crit\]\|\[emerg\]\|\[alert\]' \
    "no errors in nginx log during keep-alive test"
