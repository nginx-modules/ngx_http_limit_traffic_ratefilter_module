limit_traffic_rate module
=========================

Notes
-----

Nginx directive `limit_rate` could limit connection's speed, and `limit_conn` could limit connection number by given variable. If the client is a browser, it only open one connection to the server. The speed will be limited to `limit_rate`, unless the client is a multi-thread download tool.

`ngx_http_limit_traffic_ratefilter_module` provides a method to limit the total download rate by client IP or download URL, even there are several connections. The limit condition could be defined by the following directive.

To install, compile nginx with this ./configure option:

    --add-module=path/to/this/directory

The limit_traffic_rate module need to use a share memory pool.

Directive syntax is same to limit_zone
--------------------------------------

```nginx
http {
    #limit_traffic_rate_zone   rate $request_uri 32m;
    limit_traffic_rate_zone   rate $remote_addr 32m;

    server {
        location /download/ {
            limit_traffic_rate  rate 20k;
        }
    }
}
```

Changelogs
==========

    v0.2 
    - modify algorithm, rate = (limit - last_rate)/conn + last_rate
    
    v0.1
    - first release

License
=======

Same as nginx:

```
/* 
 * Copyright (C) 2010 Simon(bigplum@gmail.com)
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY AUTHOR AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL AUTHOR OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */
```
