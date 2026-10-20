#!/usr/bin/env bash
# Verify that ngx_http_write_filter does not overwrite the module's limit.
# Deliberately set a much higher core limit_rate in the same location.

source "$(dirname "$0")/helpers.sh"

tap_plan 4
trap _cleanup EXIT
check_requirements

BYTES=1048576  # 1 MiB; ~16 seconds at 64 KiB/s
init_test_dir "core-rate"
make_file "$TEST_DIR/files/large.bin" "$BYTES"
preamble="$(get_load_module_preamble)"
cat > "$NGINX_CONF" <<NGINXCONF
${preamble}
worker_processes 1;
pid $TEST_DIR/nginx.pid;
error_log $TEST_DIR/logs/error.log debug;
events { worker_connections 128; }
http {
    limit_traffic_rate_zone bucket \$remote_addr 2m;
    server {
        listen ${TEST_PORT};
        location /files/ {
            root $TEST_DIR;
            limit_rate 10m;
            limit_traffic_rate bucket 64k;
        }
    }
}
NGINXCONF
start_nginx

assert_http_status "http://127.0.0.1:${TEST_PORT}/files/large.bin" "200" \
    "core limit_rate plus module configuration accepted"

start=$(date +%s%N)
curl_status=0
curl -fsS --max-time 45 -o "$TEST_DIR/downloads/large.bin" \
    "http://127.0.0.1:${TEST_PORT}/files/large.bin" || curl_status=$?
elapsed=$(( ($(date +%s%N) - start + 999999999) / 1000000000 ))

if [ "$curl_status" -eq 0 ] \
    && cmp -s "$TEST_DIR/files/large.bin" "$TEST_DIR/downloads/large.bin"; then
    tap_ok "body downloaded intact"
else
    tap_fail "body integrity" "curl status=$curl_status"
fi

# A 10 MiB/s core limit alone would complete far faster than 8 seconds.
if [ "$elapsed" -ge 8 ] && [ "$elapsed" -le 35 ]; then
    tap_ok "module limit overrides faster core limit_rate (${elapsed}s)"
else
    tap_fail "module rate precedence" "expected 8..35s, got ${elapsed}s"
fi

assert_no_error_in_log '\[crit\]\|\[emerg\]' \
    "no critical nginx diagnostics"
