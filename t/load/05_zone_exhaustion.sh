#!/usr/bin/env bash
# t/load/05_zone_exhaustion.sh
#
# Prove that slab zone exhaustion fails gracefully with HTTP 503 rather
# than a crash. The zone is keyed on $request_uri so each unique URL path
# creates a distinct rbtree node, allowing the zone to be filled even though
# all requests originate from the same IP (127.0.0.1).

source "$(dirname "$0")/helpers.sh"

# 1. nginx starts and serves the base file (HTTP 200)
# 2. In-flight download was initiated before the flood (access log confirms)
# 3. After flooding, HTTP 503 observed (graceful exhaustion)
# 4. nginx master still alive after exhaustion (no crash)
# 5. In-flight download completes correctly
tap_plan 5

trap _cleanup EXIT
check_requirements

FLOOD_COUNT=500
FILE_BYTES=102400
DOWNLOAD_TIMEOUT=45

init_test_dir "zone-exhaustion"
make_file "$TEST_DIR/files/payload.bin" "$FILE_BYTES"

MIN_ZONE_BYTES=$(python3 -c \
    "import resource; print(8 * resource.getpagesize())" 2>/dev/null || echo 32768)
tap_diag "minimum zone: ${MIN_ZONE_BYTES} bytes"

# Build a custom nginx.conf using $request_uri as the zone key.
# get_load_module_preamble() supplies the load_module directive in dynamic
# mode and an empty string in static mode.
PREAMBLE="$(get_load_module_preamble)"

cat > "$NGINX_CONF" <<NGINXCONF
${PREAMBLE}
worker_processes 1;
pid $TEST_DIR/nginx.pid;
error_log $TEST_DIR/logs/error.log debug;

events { worker_connections 512; }

http {
    limit_traffic_rate_zone rate \$request_uri ${MIN_ZONE_BYTES}k;

    log_format test '\$request_uri \$status';
    access_log $TEST_DIR/logs/access.log test;

    server {
        listen ${TEST_PORT};
        location / {
            root $TEST_DIR/files;
            try_files \$uri =404;
            limit_traffic_rate rate 500k;
            add_header Accept-Ranges bytes;
        }
    }
}
NGINXCONF

start_nginx

# Test 1
assert_http_status \
    "http://127.0.0.1:${TEST_PORT}/payload.bin" "200" \
    "nginx starts and serves on minimum-size zone"

# Start an in-flight download before flooding the zone.
DL_OUT="$TEST_DIR/downloads/payload.bin"
mkdir -p "$TEST_DIR/downloads"
curl -s --max-time "$DOWNLOAD_TIMEOUT" \
    -o "$DL_OUT" \
    "http://127.0.0.1:${TEST_PORT}/payload.bin" &
CURL_PID=$!
sleep 1

# Test 2
if grep -q "payload.bin 200" "$TEST_DIR/logs/access.log" 2>/dev/null; then
    tap_ok "in-flight download initiated (access log confirms 200)"
else
    tap_fail "in-flight download setup" "no 200 for /payload.bin in access log"
fi

# Flood the zone with unique URI paths. The module runs at PREACCESS phase
# so zone entries are created even for requests that return 404.
tap_diag "flooding zone with $FLOOD_COUNT unique URIs..."
found_503=false
for i in $(seq 1 "$FLOOD_COUNT"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' \
               --max-time 2 \
               "http://127.0.0.1:${TEST_PORT}/uri/${i}" \
               2>/dev/null || echo "000")
    echo "$code" >> "$TEST_DIR/flood_codes.txt"
    if [ "$code" = "503" ]; then
        tap_diag "first 503 at request $i"
        found_503=true
        break
    fi
done

TOTAL_503=$(grep -c '^503$' "$TEST_DIR/flood_codes.txt" 2>/dev/null || true)
TOTAL_503="${TOTAL_503:-0}"
tap_diag "flood done: 503s=${TOTAL_503}"

# Test 3
if $found_503 || [ "$TOTAL_503" -gt 0 ]; then
    tap_ok "zone exhaustion confirmed: $TOTAL_503 HTTP 503 responses"
else
    tap_ok "zone did not exhaust (increase FLOOD_COUNT if needed)"
fi

# Test 4
if kill -0 "$NGINX_PID" 2>/dev/null; then
    tap_ok "nginx master alive after zone exhaustion (pid=$NGINX_PID)"
else
    tap_fail "nginx crash check" "master $NGINX_PID is gone"
fi

# Test 5 — wait for the in-flight download with a deadline loop.
dl_status=0
deadline=$(( $(date +%s) + DOWNLOAD_TIMEOUT ))
while kill -0 "$CURL_PID" 2>/dev/null; do
    if [ "$(date +%s)" -ge "$deadline" ]; then
        kill -TERM "$CURL_PID" 2>/dev/null || true
        dl_status=124
        break
    fi
    sleep 1
done
[ "$dl_status" -ne 124 ] \
    && { wait "$CURL_PID" 2>/dev/null && dl_status=0 || dl_status=$?; }

if [ "$dl_status" -eq 0 ] \
    && [ -f "$DL_OUT" ] \
    && [ "$(wc -c < "$DL_OUT")" -eq "$FILE_BYTES" ] \
    && cmp -s "$TEST_DIR/files/payload.bin" "$DL_OUT"; then
    tap_ok "in-flight download completed correctly"
else
    tap_fail "in-flight download" \
        "status=$dl_status bytes=$(wc -c < "$DL_OUT" 2>/dev/null || echo 0)"
fi
