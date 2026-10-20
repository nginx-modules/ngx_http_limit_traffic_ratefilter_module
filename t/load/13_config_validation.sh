#!/usr/bin/env bash
# Configuration rejection regression: malformed key variable, rate and zone.

source "$(dirname "$0")/helpers.sh"

tap_plan 4
trap _cleanup EXIT
check_requirements
init_test_dir "config-validation"
preamble="$(get_load_module_preamble)"

# Reject without starting nginx; a successful -t would be a regression.
expect_invalid() {
    local name="$1" directives="$2" expected="$3"
    cat > "$NGINX_CONF" <<NGINXCONF
${preamble}
worker_processes 1;
pid $TEST_DIR/nginx.pid;
error_log $TEST_DIR/logs/error.log notice;
events { worker_connections 32; }
http {
${directives}
    server { listen ${TEST_PORT}; }
}
NGINXCONF
    local diagnostic
    if diagnostic=$("$NGINX_BIN" -t -c "$NGINX_CONF" 2>&1); then
        tap_fail "$name" "nginx incorrectly accepted invalid configuration"
    elif grep -q "$expected" <<< "$diagnostic"; then
        tap_ok "$name"
    else
        tap_fail "$name" "unexpected error: $diagnostic"
    fi
}

expect_invalid "reject dollar-only variable" \
    '    limit_traffic_rate_zone bucket $ 1m;' 'invalid variable name'
expect_invalid "reject missing dollar variable prefix" \
    '    limit_traffic_rate_zone bucket remote_addr 1m;' 'invalid variable name'
expect_invalid "reject zero rate" \
    $'    limit_traffic_rate_zone bucket $remote_addr 1m;\n    limit_traffic_rate bucket 0;' \
    'rate must be positive'
expect_invalid "reject undersized shared memory zone" \
    '    limit_traffic_rate_zone bucket $remote_addr 1k;' 'too small'
