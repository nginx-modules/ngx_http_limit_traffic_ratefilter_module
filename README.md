# ngx_http_limit_traffic_rate_filter_module

![NGINX HTTP Limit Traffic Rate Filter Module Logo - ngx_http_limit_traffic_ratefilter_module](https://repository-images.githubusercontent.com/18655148/3960c9c3-cc0d-4e52-8e35-b1993eecc27d)

> **Next-generation project:** [ngx_traffic_governor](https://github.com/nginx-modules/ngx_traffic_governor)
> is planned as a multi-protocol successor covering HTTP and non-HTTP traffic.
> This repository remains the HTTP-only 2.x module; the new project is under
> development and is not yet a drop-in replacement.

Shares a configured download bandwidth among concurrent requests with the
same key (e.g. `$remote_addr`), including connections handled by different
nginx worker processes.

nginx's built-in `limit_rate` caps each connection individually. A client
using a multi-threaded download tool can open *N* connections and receive
*N × limit_rate* in aggregate. This module tracks all active connections for
a given key in a shared-memory zone and calculates an approximate fair share:

```
per-request rate = max(1 byte/s, configured_limit / active_requests)
```

Each request refreshes its own rate on subsequent output body-filter calls.
**Rates are not pushed immediately to sibling requests across workers.**
In particular, the sum of actual throughput is not a strict instantaneous
ceiling while membership changes. For a hard aggregate byte budget across
workers, a different scheduling design is needed (a candidate for v3.0.0).

## Requirements

- nginx 1.21.5 or later (documented minimum; CI currently builds 1.26.3,
  1.28.2 and 1.29.6, not the minimum)
- A C compiler supported by your nginx build (code uses C89-style declarations)

## Installation

### Static module

```bash
./configure --add-module=/path/to/this/directory
make && make install
```

### Dynamic module

```bash
./configure --add-dynamic-module=/path/to/this/directory
make && make install
```

Add to the top of `nginx.conf`, before any `events {}` or `http {}` block:

```nginx
load_module modules/ngx_http_limit_traffic_rate_filter_module.so;
```

## Configuration

### `limit_traffic_rate_zone`

Declares a named shared-memory zone. Place in the `http {}` context.

```
Syntax:  limit_traffic_rate_zone <name> <$variable> <size>;
Context: http
```

| Parameter | Description |
|---|---|
| `name` | Zone identifier referenced by `limit_traffic_rate` |
| `$variable` | nginx variable used as the grouping key |
| `size` | Shared memory size (e.g. `32m`). Minimum is 8 × page size |

Common key variables:

| Variable | Effect |
|---|---|
| `$remote_addr` | One bucket per client IP — the typical use case |
| `$binary_remote_addr` | Compact IP form, saves ~10 bytes per node |
| `$request_uri` | One bucket per URL — limit per-file across all clients |

### `limit_traffic_rate`

Applies a zone's limit within a context.

```
Syntax:  limit_traffic_rate <zone_name> <rate>;
Context: http, server, location
```

Rate units: `k` (kilobytes/sec), `m` (megabytes/sec), or plain bytes/sec.

## Example

```nginx
http {
    # One rate bucket per client IP, 32 MB of shared memory.
    limit_traffic_rate_zone  rate  $remote_addr  32m;

    server {
        # Target aggregate bandwidth per IP: 500 KiB/s.
        # With 8 steady requests, each gets about 62.5 KiB/s.
        location /download/ {
            limit_traffic_rate  rate  500k;
        }
    }
}
```

## Behaviour

**Rate sharing.** A shared counter tracks active requests for each key.
Joining requests receive their own share immediately. Existing requests learn
of additions/removals when their output body filter runs again. The module
sets `r->limit_rate_set` so the nginx write filter respects its chosen rate.
The module's `limit_traffic_rate` takes precedence over the native nginx
`limit_rate` in matching locations; the core `limit_rate_after` still applies.

**Approximation, not a strict aggregate cap.** Refresh timing depends on nginx
output scheduling and buffering; it is not synchronous across workers. The
integer division is floored at 1 byte/s because zero disables nginx rate
limiting. When the number of active requests exceeds the configured limit
in bytes/s, the combined floor may exceed that limit. The core rate limiter
can also permit initial bursts. This release does not implement cross-worker
token-bucket accounting or provide a hard aggregate throughput guarantee.

**Admission and overload.** The shared counter is a `u_short`: once a key has
65,535 active registered requests, additional requests for that key receive
HTTP 503 instead of wrapping the counter. An exhausted shared-memory slab
also produces HTTP 503. No durable worker-crash recovery is implemented:
if a worker is killed without request cleanup, a stale count can persist until
the shared zone is recreated. Normal request completion and client aborts
perform cleanup via the request pool.

**Passthrough.** The module does not apply a limit when no `limit_traffic_rate`
directive is present, the key variable is empty or not found, or the key
value exceeds 1024 bytes.

## Validation

The load tests under `t/load/` run with either a statically compiled module
or a dynamically loaded `.so`. CI configures nginx versions `1.26.3`,
`1.28.2` and `1.29.6` in both modes. The test suite includes multi-worker
throughput, nginx `limit_rate` precedence, invalid configuration, request
cleanup, graceful reload, concurrent shared-zone exhaustion and a
5,000-request repeated-allocation test.

```bash
# After building nginx with the module, using your actual binary:
TEST_NGINX_BINARY=/path/to/nginx/sbin/nginx bash t/load/run_all.sh

# Run only the multi-worker bandwidth and write-filter regressions:
TEST_NGINX_BINARY=/path/to/nginx/sbin/nginx \
    bash t/load/run_all.sh 11 12
```

The tests cover selected workloads; they do not establish strict aggregate
bandwidth guarantees, failure recovery after `SIGKILL`, or compatibility with
every nginx build and output-filter combination.

## License

```
Copyright (C) 2010 Simon (bigplum@gmail.com).  
Copyright (C) 2016-2026 Denis Denisov.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice,
   this list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA,
OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```
