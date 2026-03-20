#!/usr/bin/env bash
# t/load/09_module_decline.sh
#
# Verify that the module correctly declines (passes through without acting)
# in every case where it should not apply a limit, and that declining never
# crashes nginx or blocks the request.
#
# The module's handler returns NGX_DECLINED in four cases:
#   1. No shm_zone configured for this location (limit_traffic_rate absent)
#   2. Variable value not found / empty (vv->not_found or vv->len == 0)
#   3. Variable value is over 1024 bytes
#
# NOTE ON root vs alias:
#   With 'root DIR' nginx appends the full URI to DIR.
#   location /unlimited/ + root $TEST_DIR/files → looks for
#     $TEST_DIR/files/unlimited/test.bin  (does not exist)
#   With 'alias DIR/' nginx replaces the location prefix.
#   location /unlimited/ + alias $TEST_DIR/files/ → looks for
#     $TEST_DIR/files/test.bin  (correct)
#   All locations in this test use alias for this reason.

source "$(dirname "$0")/helpers.sh"

# 1. Location with no limit_traffic_rate: full speed passthrough
# 2. Empty variable ($arg_key absent): module declines, request passes through
# 3. Variable value > 1024 bytes: module declines, request passes through
# 4. Normal limited location still works after the decline cases
# 5. No crit/emerg errors in nginx log
tap_plan 5

trap _cleanup EXIT
check_requirements

FILE_BYTES=65536
init_test_dir "decline"
make_file "$TEST_DIR/files/test.bin" "$FILE_BYTES"

preamble="$(get_load_module_preamble)"

cat > "$NGINX_CONF" <<NGINXCONF
${preamble}
worker_processes 1;
pid $TEST_DIR/nginx.pid;
error_log $TEST_DIR/logs/error.log debug;

events { worker_connections 64; }

http {
    limit_traffic_rate_zone rate_real   \$remote_addr 2m;
    limit_traffic_rate_zone rate_custom \$arg_key     2m;

    server {
        listen ${TEST_PORT};

        # No limit_traffic_rate — module must NGX_DECLINED and pass through.
        location /unlimited/ {
            alias $TEST_DIR/files/;
        }

        # \$arg_key is empty when ?key= is absent from the URL.
        # The module must decline without blocking or returning an error.
        location /empty-var/ {
            alias $TEST_DIR/files/;
            limit_traffic_rate rate_custom 100k;
        }

        # Normal rate-limited location used to verify zone health after
        # the decline tests have run.
        location /limited/ {
            alias $TEST_DIR/files/;
            limit_traffic_rate rate_real 100k;
        }
    }
}
NGINXCONF

start_nginx

# Test 1 — no limit directive: request passes through at full speed
tap_diag "testing unlimited location..."
mkdir -p "$TEST_DIR/downloads"
out="$TEST_DIR/downloads/unlimited.bin"
t_start=$(date +%s%N)
curl -s --max-time 10 -o "$out" \
    "http://127.0.0.1:${TEST_PORT}/unlimited/test.bin"
elapsed=$(( ($(date +%s%N) - t_start + 999999999) / 1000000000 ))
bytes=$(wc -c < "$out" 2>/dev/null || echo 0)
tap_diag "unlimited: ${bytes}B in ${elapsed}s"

if [ "$bytes" -eq "$FILE_BYTES" ] && [ "$elapsed" -le 3 ]; then
    tap_ok "unlimited location: full speed (${elapsed}s, ${bytes}B)"
else
    tap_fail "unlimited location passthrough" \
        "${bytes}B in ${elapsed}s — module may be incorrectly throttling"
fi

# Test 2 — empty variable: module declines, request serves normally
tap_diag "testing empty variable (no ?key= in URL)..."
out2="$TEST_DIR/downloads/emptyvar.bin"
t2=$(date +%s%N)
code=$(curl -s --max-time 10 -o "$out2" -w '%{http_code}' \
    "http://127.0.0.1:${TEST_PORT}/empty-var/test.bin")
elapsed2=$(( ($(date +%s%N) - t2 + 999999999) / 1000000000 ))
bytes2=$(wc -c < "$out2" 2>/dev/null || echo 0)
tap_diag "empty-var: HTTP $code, ${bytes2}B in ${elapsed2}s"

if [ "$code" = "200" ] && [ "$bytes2" -eq "$FILE_BYTES" ]; then
    tap_ok "empty variable: passes through (HTTP 200, ${bytes2}B)"
else
    tap_fail "empty variable decline" \
        "HTTP $code, ${bytes2}B — module may be blocking on empty variable"
fi

# Test 3 — variable value > 1024 bytes: module logs warning and declines
# The 1025-byte ?key= value exceeds the module's 1024-byte limit check.
# The request must still be served normally (not 500 or connection reset).
long_key=$(python3 -c "print('x' * 1025)")
out3="$TEST_DIR/downloads/longvar.bin"
code3=$(curl -s --max-time 10 -o "$out3" -w '%{http_code}' \
    "http://127.0.0.1:${TEST_PORT}/empty-var/test.bin?key=${long_key}")
bytes3=$(wc -c < "$out3" 2>/dev/null || echo 0)
tap_diag "long-var: HTTP $code3, ${bytes3}B"

if [ "$code3" = "200" ] && [ "$bytes3" -eq "$FILE_BYTES" ]; then
    tap_ok "1025-byte variable: module declines, passes through (HTTP 200)"
else
    tap_fail "long variable decline" \
        "HTTP $code3, ${bytes3}B — module may be crashing on long variable"
fi

# Test 4 — normal limited location still functional after decline tests
code4=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 5 \
    "http://127.0.0.1:${TEST_PORT}/limited/test.bin")
if [ "$code4" = "200" ]; then
    tap_ok "limited location functional after decline tests (HTTP 200)"
else
    tap_fail "limited location health" "HTTP $code4"
fi

# Test 5 — warn in log is acceptable; crit/emerg is not
assert_no_error_in_log '\[crit\]\|\[emerg\]' \
    "no critical errors for decline edge cases"
