# ngx_http_limit_traffic_rate_filter_module

![NGINX HTTP Limit Traffic Rate Filter Module Logo - ngx_http_limit_traffic_ratefilter_module](https://repository-images.githubusercontent.com/18655148/3960c9c3-cc0d-4e52-8e35-b1993eecc27d)

Limits the **total** download bandwidth for all connections sharing the same
key (e.g. `$remote_addr`), regardless of how many parallel connections the
client opens.

nginx's built-in `limit_rate` caps each connection individually. A client
using a multi-threaded download tool can open *N* connections and receive
*N × limit_rate* in aggregate. This module tracks all active connections for
a given key in a shared memory zone and assigns each one an equal slice:

```
per-connection rate = configured_limit / active_connections
```

The rate is recalculated and pushed to all sibling connections whenever one
joins or leaves, so the aggregate throughput stays at or below the configured
ceiling at all times.

## Requirements

- nginx 1.21.5 or later
- GCC 4+ or Clang 3+ (C89-compatible)

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
        # Total bandwidth per IP capped at 500 KB/s.
        # A client with 8 parallel connections gets 62.5 KB/s each.
        location /download/ {
            limit_traffic_rate  rate  500k;
        }
    }
}
```

## Behaviour

**Rate sharing.** When a new connection from the same key arrives the module
increments the connection counter and immediately lowers `r->limit_rate` on
all existing sibling connections. When a connection closes the counter is
decremented and surviving siblings are raised back up.

**Graceful degradation.** If the shared memory zone is exhausted the module
returns HTTP 503 rather than crashing or silently disabling limiting.

**Passthrough.** The module does not apply a limit when no `limit_traffic_rate`
directive is present, the key variable is empty or not found, or the key
value exceeds 1024 bytes.

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
