#!/usr/bin/env bash
# Exercise *actual* concurrent slab exhaustion, rather than sequential 404s.
# Distinct long keys must remain in flight while the zone fills.  A 503 is
# required; lack of exhaustion is a failure, not a passing test.

source "$(dirname "$0")/helpers.sh"

tap_plan 6
trap _cleanup EXIT
check_requirements

FLOOD_COUNT=64
FILE_BYTES=2097152  # At 100 KiB/s the clients stay active ~20s.

init_test_dir "zone-exhaustion"
make_file "$TEST_DIR/files/payload.bin" "$FILE_BYTES"
MIN_ZONE_BYTES=$(python3 -c \
    'import resource; print(8 * resource.getpagesize())')
preamble="$(get_load_module_preamble)"

cat > "$NGINX_CONF" <<NGINXCONF
${preamble}
worker_processes 1;
pid $TEST_DIR/nginx.pid;
error_log $TEST_DIR/logs/error.log notice;
events { worker_connections 256; }
http {
    limit_traffic_rate_zone bucket \$arg_key ${MIN_ZONE_BYTES};
    server {
        listen ${TEST_PORT};
        location /files/ {
            root $TEST_DIR;
            limit_traffic_rate bucket 100k;
        }
    }
}
NGINXCONF
start_nginx

assert_http_status "http://127.0.0.1:${TEST_PORT}/files/payload.bin" "200" \
    "minimum zone accepted and serves unkeyed requests"

# Hold one transfer while creating many distinct concurrent key nodes.
# The initial transfer has its own key and must survive the 503 storm.
DL_OUT="$TEST_DIR/downloads/held.bin"
curl -fsS --max-time 55 -o "$DL_OUT" \
    "http://127.0.0.1:${TEST_PORT}/files/payload.bin?key=held" &
HOLD_PID=$!
sleep 1
if kill -0 "$HOLD_PID" 2>/dev/null; then
    tap_ok "initial limited transfer is still in flight"
else
    tap_fail "in-flight transfer setup" "request completed unexpectedly early"
fi

pids=()
for i in $(seq 1 "$FLOOD_COUNT"); do
    # 900-byte distinct values occupy ~1 KiB slab allocations per node.
    key=$(printf '%0900d' "$i")
    curl -s --max-time 50 -o /dev/null -w '%{http_code}\n' \
        "http://127.0.0.1:${TEST_PORT}/files/payload.bin?key=${key}" \
        > "$TEST_DIR/downloads/status-$i" &
    pids+=("$!")
done

curl_errors=0
for pid in "${pids[@]}"; do
    wait "$pid" || curl_errors=$((curl_errors + 1))
done

count_503=0
for i in $(seq 1 "$FLOOD_COUNT"); do
    code=$(cat "$TEST_DIR/downloads/status-$i")
    if [ "$code" = "503" ]; then
        count_503=$((count_503 + 1))
    elif [ "$code" != "200" ]; then
        tap_diag "unexpected HTTP code $code for flood request $i"
        curl_errors=$((curl_errors + 1))
    fi
done
tap_diag "flood: HTTP 503=${count_503}, other errors=${curl_errors}"
if [ "$count_503" -gt 0 ]; then
    tap_ok "shared slab exhausted with HTTP 503 ($count_503 responses)"
else
    tap_fail "zone exhaustion" "no 503 from $FLOOD_COUNT simultaneous keys"
fi

if [ "$curl_errors" -eq 0 ]; then
    tap_ok "flood requests returned only HTTP 200 or 503"
else
    tap_fail "flood response integrity" "$curl_errors unexpected failures"
fi

if kill -0 "$NGINX_PID" 2>/dev/null \
    && ! grep -Eiq 'segfault|SIGSEGV|worker process .*exited on signal' \
         "$TEST_DIR/logs/error.log"; then
    tap_ok "nginx survived actual slab exhaustion"
else
    tap_fail "nginx survival" "worker crash or master process gone"
fi

hold_status=0
wait "$HOLD_PID" || hold_status=$?
if [ "$hold_status" -eq 0 ] \
    && cmp -s "$TEST_DIR/files/payload.bin" "$DL_OUT"; then
    tap_ok "original in-flight download remained intact"
else
    tap_fail "in-flight download integrity" "curl status=$hold_status"
fi
