#!/usr/bin/env bash
# t/load/helpers.sh
# Shared utilities for all load tests. Source as the first statement:
#   source "$(dirname "$0")/helpers.sh"

set -euo pipefail

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RESET='\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; RESET=''
fi

NGINX_BIN="${TEST_NGINX_BINARY:-nginx}"
TEST_PORT="${TEST_NGINX_PORT:-18080}"

TEST_DIR=""
NGINX_PID=""
NGINX_CONF=""

TAP_CURRENT=0
TAP_FAILED=0
TAP_PLANNED=0
SCRIPT_NAME="$(basename "${BASH_SOURCE[1]:-$0}" .sh)"

# -- TAP helpers ------------------------------------------------------------

tap_plan()     { TAP_PLANNED=$1; echo "1..$1"; }
tap_diag()     { echo "# $*"; }
tap_bail_out() { echo "Bail out!  $1"; _cleanup; exit 1; }

tap_ok() {
    TAP_CURRENT=$((TAP_CURRENT + 1))
    printf "${GREEN}ok${RESET} %d - %s\n" "$TAP_CURRENT" "$1"
}

tap_fail() {
    TAP_CURRENT=$((TAP_CURRENT + 1))
    TAP_FAILED=$((TAP_FAILED + 1))
    printf "${RED}not ok${RESET} %d - %s\n" "$TAP_CURRENT" "$1"
    if [ -n "${2:-}" ]; then echo "  # FAIL: $2"; fi
}

# -- Test directory ---------------------------------------------------------

init_test_dir() {
    local prefix="${1:-load-test}"
    TEST_DIR="$(mktemp -d "/tmp/ngx-${prefix}-XXXXXX")"
    mkdir -p "$TEST_DIR/files" "$TEST_DIR/logs" "$TEST_DIR/downloads"
    # mktemp uses 700; nginx workers run as 'nobody' and need execute
    # permission on every directory component to serve files from it.
    chmod 755 "$TEST_DIR" "$TEST_DIR/files" "$TEST_DIR/logs" "$TEST_DIR/downloads"
    tap_diag "test dir: $TEST_DIR"
    NGINX_CONF="$TEST_DIR/nginx.conf"
}

make_file() {
    local path="$1" size="$2"
    truncate -s "$size" "$path"
    chmod 644 "$path"
    tap_diag "fixture: $path ($size bytes)"
}

# -- Dynamic module support -------------------------------------------------

# Prints the load_module directive for dynamic mode, empty string for static.
# Used by write_nginx_conf() and any test that writes its own nginx.conf.
get_load_module_preamble() {
    if [ "${TEST_NGINX_MODULE_MODE:-static}" = "dynamic" ]; then
        local p="${TEST_NGINX_MODULES_PATH:-/usr/local/nginx/modules}"
        echo "load_module ${p}/ngx_http_limit_traffic_rate_filter_module.so;"
    fi
}

# -- nginx config -----------------------------------------------------------

write_nginx_conf() {
    local zone_size="${1:-1m}" rate="${2:-100k}" extra="${3:-}"
    local preamble
    preamble="$(get_load_module_preamble)"

    cat > "$NGINX_CONF" <<NGINXCONF
${preamble}
worker_processes ${TEST_NGINX_WORKERS:-1};
pid $TEST_DIR/nginx.pid;
error_log $TEST_DIR/logs/error.log debug;

events { worker_connections 512; }

http {
    limit_traffic_rate_zone rate \$remote_addr ${zone_size};

    log_format test '\$remote_addr "\$request" \$status \$body_bytes_sent';
    access_log $TEST_DIR/logs/access.log test;

    server {
        listen ${TEST_PORT};

        location /files/ {
            root $TEST_DIR;
            limit_traffic_rate rate ${rate};
            add_header Accept-Ranges bytes;
        }

        location /open/ {
            root $TEST_DIR;
        }
    }

    ${extra}
}
NGINXCONF
    tap_diag "nginx.conf written (mode=${TEST_NGINX_MODULE_MODE:-static}, zone=${zone_size}, rate=${rate})"
}

# -- nginx process management -----------------------------------------------

start_nginx() {
    local test_output
    if ! test_output=$("$NGINX_BIN" -t -c "$NGINX_CONF" 2>&1); then
        echo "$test_output" | while IFS= read -r l; do tap_diag "  $l"; done
        tap_bail_out "nginx config test failed"
    fi
    tap_diag "nginx config OK"

    "$NGINX_BIN" -g 'daemon off;' -c "$NGINX_CONF" &
    NGINX_PID=$!

    local i
    for i in $(seq 1 50); do
        if nc -z 127.0.0.1 "$TEST_PORT" 2>/dev/null; then
            tap_diag "nginx ready (pid=$NGINX_PID)"; return 0
        fi
        sleep 0.1
    done

    while IFS= read -r l; do tap_diag "  $l"; done \
        < "$TEST_DIR/logs/error.log" 2>/dev/null || true
    tap_bail_out "nginx did not start within 5s on port ${TEST_PORT}"
}

stop_nginx() {
    if [ -n "${NGINX_PID:-}" ] && kill -0 "$NGINX_PID" 2>/dev/null; then
        tap_diag "stopping nginx (pid=$NGINX_PID)"
        kill -TERM "$NGINX_PID" 2>/dev/null || true
        local i
        for i in $(seq 1 30); do
            kill -0 "$NGINX_PID" 2>/dev/null || return 0
            sleep 0.1
        done
        kill -KILL "$NGINX_PID" 2>/dev/null || true
    fi
}

reload_nginx() {
    local old; old=$(get_worker_pids | tr '\n' ' ')
    kill -HUP "$NGINX_PID"
    local i
    for i in $(seq 1 50); do
        local new; new=$(get_worker_pids | tr '\n' ' ')
        if [ "$new" != "$old" ]; then
            tap_diag "reload complete: workers [$old] → [$new]"
            return 0
        fi
        sleep 0.1
    done
    tap_diag "WARNING: worker PIDs unchanged after reload"
}

get_worker_pids() {
    ps --ppid "$NGINX_PID" -o pid= 2>/dev/null \
        | tr -s ' ' '\n' | grep -v '^$' || true
}

get_worker_rss() {
    awk '/^VmRSS:/{print $2}' "/proc/${1}/status" 2>/dev/null || echo 0
}

# -- curl helpers -----------------------------------------------------------

# curl_download_parallel <url> <count> <outdir>
# Downloads <url> <count> times simultaneously. Returns elapsed seconds.
curl_download_parallel() {
    local url="$1" count="$2" outdir="$3"
    mkdir -p "$outdir"

    local pids=() i t_start
    t_start=$(date +%s%N)

    for i in $(seq 1 "$count"); do
        curl -s --max-time 120 -o "${outdir}/download-${i}.bin" "$url" &
        pids+=($!)
    done
    tap_diag "started $count parallel curl downloads"

    local failed=0
    for pid in "${pids[@]}"; do wait "$pid" || failed=$(( failed + 1 )); done

    local elapsed
    elapsed=$(( ($(date +%s%N) - t_start + 999999999) / 1000000000 ))
    tap_diag "parallel downloads done: ${elapsed}s, ${failed} failed"
    if [ "$failed" -gt 0 ]; then return 1; fi
    echo "$elapsed"
}

# -- Assertions -------------------------------------------------------------

assert_rate_within_bounds() {
    local bytes="$1" elapsed="$2" limit="$3" tolerance="${4:-35}" name="${5:-rate check}"
    if [ "$elapsed" -le 0 ]; then
        tap_fail "$name" "elapsed is zero"; return
    fi
    local actual=$(( bytes / elapsed ))
    local lower=$(( limit * (100 - tolerance) / 100 ))
    local upper=$(( limit * (100 + tolerance) / 100 ))
    tap_diag "rate: actual=${actual}B/s limit=${limit}B/s range=[${lower},${upper}]"
    if [ "$actual" -ge "$lower" ] && [ "$actual" -le "$upper" ]; then
        tap_ok "$name (${actual} B/s within [${lower}, ${upper}])"
    else
        tap_fail "$name" "actual=${actual} B/s outside [${lower}, ${upper}] B/s"
    fi
}

assert_rss_growth_bounded() {
    local pid="$1" baseline="$2" max="$3" name="${4:-rss check}"
    local current; current=$(get_worker_rss "$pid")
    local growth=$(( current - baseline ))
    tap_diag "rss: baseline=${baseline}KB current=${current}KB growth=${growth}KB limit=${max}KB"
    if [ "$growth" -le "$max" ]; then
        tap_ok "$name (growth ${growth}KB ≤ ${max}KB)"
    else
        tap_fail "$name" "RSS grew ${growth}KB, limit ${max}KB"
    fi
}

assert_no_error_in_log() {
    local pattern="$1" name="${2:-no error in log}"
    if grep -q "$pattern" "$TEST_DIR/logs/error.log" 2>/dev/null; then
        tap_fail "$name" "found '$pattern' in error log"
        grep "$pattern" "$TEST_DIR/logs/error.log" \
            | while IFS= read -r l; do tap_diag "  $l"; done
    else
        tap_ok "$name"
    fi
}

assert_http_status() {
    local url="$1" expected="$2" name="${3:-http status}"
    # Use HEAD (-I) so nginx replies with only the status line — no body is
    # transferred. A GET with --max-time would time out on large rate-limited
    # files and produce a concatenated result like "200000" (200 + fallback 000).
    local actual
    actual=$(curl -sI -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null || echo "000")
    if [ "$actual" = "$expected" ]; then
        tap_ok "$name (HTTP $actual)"
    else
        tap_fail "$name" "expected HTTP $expected got $actual"
    fi
}

# -- Cleanup ----------------------------------------------------------------

_cleanup() {
    tap_diag "cleanup"
    stop_nginx
    if [ "${TAP_FAILED:-0}" -gt 0 ]; then
        printf "${RED}# FAILED: %d/%d${RESET}\n" "$TAP_FAILED" "$TAP_CURRENT" >&2
    else
        printf "${GREEN}# PASSED: %d${RESET}\n" "$TAP_CURRENT" >&2
    fi
}

check_requirements() {
    local missing=0
    for bin in "$NGINX_BIN" curl nc awk python3 truncate; do
        command -v "$bin" >/dev/null 2>&1 || { tap_diag "MISSING: $bin"; missing=$(( missing + 1 )); }
    done
    if [ "${TEST_NGINX_MODULE_MODE:-static}" = "dynamic" ]; then
        local p="${TEST_NGINX_MODULES_PATH:-/usr/local/nginx/modules}"
        local so="${p}/ngx_http_limit_traffic_rate_filter_module.so"
        if [ ! -f "$so" ]; then
            tap_diag "MISSING .so: $so"; missing=$(( missing + 1 ))
        else
            tap_diag "dynamic module .so found: $so"
        fi
    fi
    if [ "$missing" -gt 0 ]; then
        tap_bail_out "$missing required files not found"
    fi
}

tap_diag "=== $SCRIPT_NAME ==="
tap_diag "nginx: $NGINX_BIN"
tap_diag "port:  $TEST_PORT"
