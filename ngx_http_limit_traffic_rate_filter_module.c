/*
 * ngx_http_limit_traffic_rate_filter_module.c
 *
 * Limits the aggregate download rate for all connections that share the
 * same key (e.g. $remote_addr).  Each connection receives an equal slice:
 *
 *     per-connection rate = configured_limit / active_connections
 *
 * Unlike nginx's built-in limit_rate (which is per-connection), this
 * module tracks concurrent connections in shared memory so the total
 * throughput for one key stays at or below the configured ceiling even
 * when a client opens multiple parallel connections.
 */

#include <ngx_config.h>
#include <ngx_core.h>
#include <ngx_http.h>


/* -- forward declarations --------------------------------------------------- */

static ngx_int_t ngx_http_limit_traffic_rate_filter_handler(
    ngx_http_request_t *r);
static ngx_int_t ngx_http_limit_traffic_rate_filter_init(
    ngx_conf_t *cf);
static ngx_int_t ngx_http_limit_traffic_rate_body_filter(
    ngx_http_request_t *r, ngx_chain_t *in);
static ngx_int_t ngx_http_limit_traffic_rate_filter_log_handler(
    ngx_http_request_t *r);
static void *ngx_http_limit_traffic_rate_filter_create_loc_conf(
    ngx_conf_t *cf);
static char *ngx_http_limit_traffic_rate_filter_merge_loc_conf(
    ngx_conf_t *cf, void *parent, void *child);
static ngx_int_t ngx_http_limit_traffic_rate_filter_init_zone(
    ngx_shm_zone_t *shm_zone, void *data);
static void ngx_http_limit_traffic_rate_filter_rbtree_insert_value(
    ngx_rbtree_node_t *temp, ngx_rbtree_node_t *node,
    ngx_rbtree_node_t *sentinel);
static void ngx_http_limit_traffic_rate_filter_cleanup(void *data);
static char *ngx_http_limit_traffic_rate_zone(
    ngx_conf_t *cf, ngx_command_t *cmd, void *conf);
static char *ngx_http_limit_traffic_rate(
    ngx_conf_t *cf, ngx_command_t *cmd, void *conf);


/* -- data structures -------------------------------------------------------- */

/*
 * One entry per active request, stored in the shared-memory queue attached
 * to the rbtree node for this key.  We only need the request pointer so
 * that ngx_http_limit_traffic_rate_update_all() can write r->limit_rate on
 * every sibling.  The per-request timing fields from the original design
 * are removed: rate enforcement is now delegated entirely to nginx's own
 * ngx_http_write_filter via r->limit_rate.
 */
typedef struct {
    ngx_queue_t          rq;   /* intrusive queue link; must be first member */
    ngx_http_request_t  *r;    /* owning request; set NULL before queue_remove */
} ngx_http_limit_traffic_rate_node_req_t;

/*
 * Stored in the pool cleanup data so the cleanup handler can find both the
 * rbtree node and the specific queue entry to remove as a safety net.
 */
typedef struct {
    ngx_shm_zone_t      *shm_zone;
    ngx_rbtree_node_t   *node;
    ngx_http_request_t  *r;     /* back-pointer for queue scan in cleanup */
} ngx_http_limit_traffic_rate_cleanup_t;

/*
 * Red-black tree node payload.  The struct is deliberately aliased from
 * rbtree_node.color (via the "&node->color" cast pattern used throughout
 * nginx) so that a single slab allocation covers both the rbtree
 * bookkeeping and our per-key data.
 *
 * Memory layout inside one slab block:
 *
 *   [ ngx_rbtree_node_t fields up to .color ]
 *   [ ngx_http_limit_traffic_rate_node_t    ] <- &node->color
 *       .color, .len, .conn, .start_sec, .rq_top
 *   [ variable-length key bytes             ] <- .data[0 .. len-1]
 */
typedef struct {
    u_char      color;      /* MUST be first: aliased from rbtree_node.color */
    u_short     len;        /* byte length of the key value stored in data[] */
    u_short     conn;       /* count of currently active connections for key */
    time_t      start_sec;
    ngx_queue_t rq_top;    /* sentinel head of the per-key request queue     */
    u_char      data[1];   /* flexible key bytes; actual alloc covers len    */
} ngx_http_limit_traffic_rate_node_t;

typedef struct {
    ngx_rbtree_t  *rbtree;
    ngx_int_t      index;   /* pre-computed index of the tracked variable     */
    ngx_str_t      var;     /* human-readable variable name for log messages  */
} ngx_http_limit_traffic_rate_ctx_t;

typedef struct {
    size_t          limit_traffic_rate;  /* configured ceiling in bytes/sec  */
    ngx_shm_zone_t *shm_zone;
} ngx_http_limit_traffic_rate_conf_t;


/* -- module directives ------------------------------------------------------ */

static ngx_command_t ngx_http_limit_traffic_rate_filter_commands[] = {

    /*
     * limit_traffic_rate_zone  <name>  <$variable>  <size>;
     *
     * Declares a shared-memory zone keyed on <$variable>.
     * Example: limit_traffic_rate_zone  rate  $remote_addr  32m;
     */
    { ngx_string("limit_traffic_rate_zone"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE3,
      ngx_http_limit_traffic_rate_zone,
      0, 0, NULL },

    /*
     * limit_traffic_rate  <zone_name>  <rate>;
     *
     * Applies the zone limit within a location block.
     * Example: limit_traffic_rate  rate  20k;
     */
    { ngx_string("limit_traffic_rate"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE2,
      ngx_http_limit_traffic_rate,
      NGX_HTTP_LOC_CONF_OFFSET, 0, NULL },

    ngx_null_command
};


static ngx_http_module_t ngx_http_limit_traffic_rate_filter_module_ctx = {
    NULL,                                                /* preconfiguration  */
    ngx_http_limit_traffic_rate_filter_init,             /* postconfiguration */
    NULL, NULL,                                          /* main conf         */
    NULL, NULL,                                          /* server conf       */
    ngx_http_limit_traffic_rate_filter_create_loc_conf,  /* create loc conf   */
    ngx_http_limit_traffic_rate_filter_merge_loc_conf    /* merge loc conf    */
};


ngx_module_t ngx_http_limit_traffic_rate_filter_module = {
    NGX_MODULE_V1,
    &ngx_http_limit_traffic_rate_filter_module_ctx,
    ngx_http_limit_traffic_rate_filter_commands,
    NGX_HTTP_MODULE,
    NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NGX_MODULE_V1_PADDING
};

static ngx_http_output_body_filter_pt ngx_http_next_body_filter;


/* -- internal helper -------------------------------------------------------- */

/*
 * ngx_http_limit_traffic_rate_update_all
 *
 * Iterates every entry in lir's request queue and writes the correct
 * per-connection rate into each sibling request's r->limit_rate field.
 *
 * Must be called with shpool->mutex held.
 *
 * Why this is safe without a per-request lock:
 *   nginx workers are single-threaded; only one request executes at a time
 *   within a given worker.  We are running inside the event loop, so no
 *   other request in this worker can be mid-flight while we assign its
 *   r->limit_rate.  Workers in other processes have their own copies of r
 *   and never share a request pointer.
 *
 * Called on both connection entry (new sibling lowers everyone's share)
 * and connection exit (cleanup handler raises the surviving shares).
 */
static void
ngx_http_limit_traffic_rate_update_all(
    ngx_http_limit_traffic_rate_node_t  *lir,
    ngx_http_limit_traffic_rate_conf_t  *lircf)
{
    ngx_queue_t                           *q;
    ngx_http_limit_traffic_rate_node_req_t *tr;
    size_t                                 per_conn;

    if (lir->conn == 0) {
        return; /* nothing to update; guard the division below */
    }

    per_conn = lircf->limit_traffic_rate / lir->conn;

    for (q  = ngx_queue_head(&lir->rq_top);
         q != ngx_queue_sentinel(&lir->rq_top);
         q  = ngx_queue_next(q))
    {
        tr = ngx_queue_data(q, ngx_http_limit_traffic_rate_node_req_t, rq);

        if (tr->r != NULL) {
            /*
             * r->limit_rate is consumed by ngx_http_write_filter_module.
             * It chunks output and arms a write-event timer automatically,
             * so we do not need to manage timers or delays ourselves.
             */
            tr->r->limit_rate = per_conn;
        }
    }
}


/* -- PREACCESS phase: register a new connection for a key ------------------ */

static ngx_int_t
ngx_http_limit_traffic_rate_filter_handler(ngx_http_request_t *r)
{
    /*
     * C89: ALL declarations before ANY statements.
     * Do not move any declaration below the first executable line.
     */
    size_t                                  len, n;
    uint32_t                                hash;
    ngx_int_t                               rc;
    ngx_slab_pool_t                        *shpool;
    ngx_rbtree_node_t                      *node, *sentinel;
    ngx_pool_cleanup_t                     *cln;
    ngx_http_variable_value_t              *vv;
    ngx_http_limit_traffic_rate_ctx_t      *ctx;
    ngx_http_limit_traffic_rate_node_t     *lir;
    ngx_http_limit_traffic_rate_conf_t     *lircf;
    ngx_http_limit_traffic_rate_cleanup_t  *lircln;
    ngx_http_limit_traffic_rate_node_req_t *req;

    lircf = ngx_http_get_module_loc_conf(r,
                ngx_http_limit_traffic_rate_filter_module);

    if (lircf->shm_zone == NULL) {
        return NGX_DECLINED;
    }

    ctx = lircf->shm_zone->data;
    vv  = ngx_http_get_indexed_variable(r, ctx->index);

    if (vv == NULL || vv->not_found) {
        return NGX_DECLINED;
    }

    len = vv->len;

    if (len == 0) {
        return NGX_DECLINED;
    }

    if (len > 1024) {
        ngx_log_error(NGX_LOG_ERR, r->connection->log, 0,
                      "the value of the \"%V\" variable "
                      "is more than 1024 bytes: \"%v\"",
                      &ctx->var, vv);
        return NGX_DECLINED;
    }

    hash = ngx_crc32_short(vv->data, len);

    /*
     * Allocate the pool cleanup record BEFORE locking.  Pool allocation
     * cannot sleep or fail inside a spinlock, but more importantly we want
     * to avoid holding the shmtx while doing any request-pool work.
     */
    cln = ngx_pool_cleanup_add(r->pool,
              sizeof(ngx_http_limit_traffic_rate_cleanup_t));
    if (cln == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    shpool = (ngx_slab_pool_t *) lircf->shm_zone->shm.addr;

    ngx_shmtx_lock(&shpool->mutex);

    node     = ctx->rbtree->root;
    sentinel = ctx->rbtree->sentinel;

    /* -- walk the rbtree looking for an existing entry for this key ---- */
    while (node != sentinel) {

        if (hash < node->key) {
            node = node->left;
            continue;
        }

        if (hash > node->key) {
            node = node->right;
            continue;
        }

        /*
         * hash == node->key: a hash collision is possible, so we must
         * compare the actual key bytes to find (or skip) this entry.
         */
        do {
            lir = (ngx_http_limit_traffic_rate_node_t *) &node->color;
            rc  = ngx_memn2cmp(vv->data, lir->data, len, (size_t) lir->len);

            if (rc == 0) {
                /*
                 * Found the node for this key.  Allocate a queue entry
                 * and add this connection to the group.
                 *
                 * We allocate req BEFORE incrementing lir->conn so that
                 * on allocation failure we can bail without corrupting the
                 * counter.
                 */
                req = ngx_slab_alloc_locked(shpool,
                          sizeof(ngx_http_limit_traffic_rate_node_req_t));
                if (req == NULL) {
                    ngx_shmtx_unlock(&shpool->mutex);
                    return NGX_HTTP_SERVICE_UNAVAILABLE;
                }

                lir->conn++;
                req->r = r;
                ngx_queue_insert_tail(&lir->rq_top, &req->rq);

                /* Redistribute rate to all connections including this one. */
                ngx_http_limit_traffic_rate_update_all(lir, lircf);

                goto done;
            }

            node = (rc < 0) ? node->left : node->right;

        } while (node != sentinel && hash == node->key);

        break;
    }

    /* -- no existing entry: create a new rbtree node ------------------- */

    n = offsetof(ngx_rbtree_node_t, color)
      + offsetof(ngx_http_limit_traffic_rate_node_t, data)
      + len;

    node = ngx_slab_alloc_locked(shpool, n);
    if (node == NULL) {
        ngx_shmtx_unlock(&shpool->mutex);
        return NGX_HTTP_SERVICE_UNAVAILABLE;
    }

    /*
     * Allocate the per-request queue entry while still holding the lock.
     * On failure we MUST free the node we just allocated — the original
     * code leaked it here (node was allocated, req allocation failed,
     * function returned without freeing node).
     */
    req = ngx_slab_alloc_locked(shpool,
              sizeof(ngx_http_limit_traffic_rate_node_req_t));
    if (req == NULL) {
        ngx_slab_free_locked(shpool, node); /* fix: prevent slab leak */
        ngx_shmtx_unlock(&shpool->mutex);
        return NGX_HTTP_SERVICE_UNAVAILABLE;
    }

    lir            = (ngx_http_limit_traffic_rate_node_t *) &node->color;
    node->key      = hash;
    lir->len       = (u_short) len;
    lir->conn      = 1;
    lir->start_sec = r->start_sec;

    ngx_queue_init(&lir->rq_top);

    req->r = r;
    ngx_queue_insert_tail(&lir->rq_top, &req->rq);

    /* First and only connection: grant the full configured rate. */
    r->limit_rate = lircf->limit_traffic_rate;

    ngx_memcpy(lir->data, vv->data, len);
    ngx_rbtree_insert(ctx->rbtree, node);

done:

    ngx_log_debug2(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                   "limit traffic rate: %08XD %d", node->key, lir->conn);

    ngx_shmtx_unlock(&shpool->mutex);

    /* Wire the cleanup handler to fire when r->pool is destroyed. */
    cln->handler = ngx_http_limit_traffic_rate_filter_cleanup;
    lircln       = cln->data;

    lircln->shm_zone = lircf->shm_zone;
    lircln->node     = node;
    lircln->r        = r;   /* used in cleanup to locate the queue entry */

    return NGX_DECLINED;
}


/* -- body filter: keep r->limit_rate accurate as siblings join/leave ------- */

/*
 * The sole purpose of this filter is to refresh r->limit_rate before each
 * write so that if the connection count changed since the last call, this
 * request's allowed bandwidth is corrected.
 *
 * All actual rate enforcement — chunking the output, arming the write-event
 * timer, sleeping between chunks — is handled by nginx's built-in
 * ngx_http_write_filter_module, which reads r->limit_rate natively.
 * We do not implement timers or delay arithmetic here.
 *
 * ngx_http_limit_traffic_rate_update_all() called from the access handler
 * and cleanup handler already pushes the new rate to all siblings on every
 * topology change, so this filter is mainly a fallback catch-up.
 */
static ngx_int_t
ngx_http_limit_traffic_rate_body_filter(ngx_http_request_t *r, ngx_chain_t *in)
{
    /* C89: all declarations before statements. */
    size_t                               len;
    uint32_t                             hash;
    ngx_int_t                            rc;
    ngx_slab_pool_t                     *shpool;
    ngx_rbtree_node_t                   *node, *sentinel;
    ngx_http_variable_value_t           *vv;
    ngx_http_limit_traffic_rate_ctx_t   *ctx;
    ngx_http_limit_traffic_rate_node_t  *lir;
    ngx_http_limit_traffic_rate_conf_t  *lircf;

    lircf = ngx_http_get_module_loc_conf(r,
                ngx_http_limit_traffic_rate_filter_module);

    if (lircf->shm_zone == NULL) {
        return ngx_http_next_body_filter(r, in);
    }

    ctx = lircf->shm_zone->data;
    vv  = ngx_http_get_indexed_variable(r, ctx->index);

    if (vv == NULL || vv->not_found || vv->len == 0 || vv->len > 1024) {
        return ngx_http_next_body_filter(r, in);
    }

    len  = vv->len;
    hash = ngx_crc32_short(vv->data, len);

    shpool = (ngx_slab_pool_t *) lircf->shm_zone->shm.addr;

    ngx_shmtx_lock(&shpool->mutex);

    node     = ctx->rbtree->root;
    sentinel = ctx->rbtree->sentinel;

    while (node != sentinel) {

        if (hash < node->key) { node = node->left;  continue; }
        if (hash > node->key) { node = node->right; continue; }

        do {
            lir = (ngx_http_limit_traffic_rate_node_t *) &node->color;
            rc  = ngx_memn2cmp(vv->data, lir->data, len, (size_t) lir->len);

            if (rc == 0) {
                if (lir->conn > 0) {
                    /*
                     * Refresh this request's limit.  The conn > 0 guard
                     * prevents division by zero on the (theoretically
                     * impossible) case where cleanup ran before the body
                     * filter for this request.
                     */
                    r->limit_rate = lircf->limit_traffic_rate / lir->conn;
                }
                goto done;
            }

            node = (rc < 0) ? node->left : node->right;

        } while (node != sentinel && hash == node->key);

        break;
    }

done:

    ngx_shmtx_unlock(&shpool->mutex);

    return ngx_http_next_body_filter(r, in);
}


/* -- LOG phase: remove the queue entry for this request (normal path) ------- */

static ngx_int_t
ngx_http_limit_traffic_rate_filter_log_handler(ngx_http_request_t *r)
{
    /* C89: all declarations before statements. */
    size_t                                  len;
    uint32_t                                hash;
    ngx_int_t                               rc;
    ngx_slab_pool_t                        *shpool;
    ngx_rbtree_node_t                      *node, *sentinel;
    ngx_http_variable_value_t              *vv;
    ngx_http_limit_traffic_rate_ctx_t      *ctx;
    ngx_http_limit_traffic_rate_node_t     *lir;
    ngx_http_limit_traffic_rate_conf_t     *lircf;
    ngx_http_limit_traffic_rate_node_req_t *tr;
    ngx_queue_t                            *q;

    lircf = ngx_http_get_module_loc_conf(r,
                ngx_http_limit_traffic_rate_filter_module);

    if (lircf->shm_zone == NULL) {
        return NGX_DECLINED;
    }

    ctx = lircf->shm_zone->data;
    vv  = ngx_http_get_indexed_variable(r, ctx->index);

    if (vv == NULL || vv->not_found || vv->len == 0 || vv->len > 1024) {
        return NGX_DECLINED;
    }

    len  = vv->len;
    hash = ngx_crc32_short(vv->data, len);

    shpool = (ngx_slab_pool_t *) lircf->shm_zone->shm.addr;

    ngx_shmtx_lock(&shpool->mutex);

    node     = ctx->rbtree->root;
    sentinel = ctx->rbtree->sentinel;

    while (node != sentinel) {

        if (hash < node->key) { node = node->left;  continue; }
        if (hash > node->key) { node = node->right; continue; }

        do {
            lir = (ngx_http_limit_traffic_rate_node_t *) &node->color;
            rc  = ngx_memn2cmp(vv->data, lir->data, len, (size_t) lir->len);

            if (rc == 0) {
                /*
                 * Walk the queue with the idiomatic sentinel comparison.
                 * The original "for (; p;)" loop was unsafe because
                 * ngx_queue_t's next pointer is never NULL (circular list).
                 */
                for (q  = ngx_queue_head(&lir->rq_top);
                     q != ngx_queue_sentinel(&lir->rq_top);
                     q  = ngx_queue_next(q))
                {
                    tr = ngx_queue_data(q,
                             ngx_http_limit_traffic_rate_node_req_t, rq);

                    if (tr->r == r) {
                        tr->r = NULL;           /* mark before removal    */
                        ngx_queue_remove(q);
                        ngx_slab_free_locked(shpool, tr);
                        goto done;
                    }
                }

                /*
                 * Entry not found: either cleanup ran first (unusual but
                 * harmless) or there is a logic error worth knowing about.
                 * Log at WARN rather than DEBUG so it surfaces in prod logs.
                 */
                ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                              "limit_traffic_rate: queue entry not found "
                              "for key %08XD in log phase — "
                              "cleanup handler will tidy up if needed",
                              node->key);
                goto done;
            }

            node = (rc < 0) ? node->left : node->right;

        } while (node != sentinel && hash == node->key);

        break;
    }

done:

    ngx_shmtx_unlock(&shpool->mutex);

    return NGX_DECLINED;
}


/* -- cleanup handler: conn decrement + unconditional safety net ------------ */

/*
 * This handler fires when r->pool is destroyed, which happens after the
 * log phase and after connection close — regardless of whether the request
 * ended normally, timed out, or was aborted.
 *
 * Responsibilities:
 *   1. Safety net: free the queue entry if the log-phase handler didn't
 *      (e.g. on abnormal teardown where log phase was skipped).
 *   2. Decrement lir->conn.
 *   3. If conn reaches zero, delete and free the rbtree node.
 *   4. Otherwise redistribute the rate across the surviving connections.
 *
 * Note on accessing r inside a pool cleanup:
 *   Pool cleanup handlers run before the pool memory is freed, so r and
 *   all fields reachable from it (including loc_conf) are still valid here.
 */
static void
ngx_http_limit_traffic_rate_filter_cleanup(void *data)
{
    /* C89: all declarations before statements. */
    ngx_http_limit_traffic_rate_cleanup_t  *lircln = data;

    ngx_slab_pool_t                        *shpool;
    ngx_rbtree_node_t                      *node;
    ngx_http_limit_traffic_rate_ctx_t      *ctx;
    ngx_http_limit_traffic_rate_node_t     *lir;
    ngx_http_limit_traffic_rate_conf_t     *lircf;
    ngx_http_limit_traffic_rate_node_req_t *tr;
    ngx_queue_t                            *q;

    ctx    = lircln->shm_zone->data;
    shpool = (ngx_slab_pool_t *) lircln->shm_zone->shm.addr;
    node   = lircln->node;
    lir    = (ngx_http_limit_traffic_rate_node_t *) &node->color;
    lircf  = ngx_http_get_module_loc_conf(lircln->r,
                 ngx_http_limit_traffic_rate_filter_module);

    ngx_shmtx_lock(&shpool->mutex);

    ngx_log_debug2(NGX_LOG_DEBUG_HTTP, lircln->shm_zone->shm.log, 0,
                   "limit traffic rate cleanup: %08XD %d",
                   node->key, lir->conn);

    /* -- step 1: safety-net queue-entry removal ------------------------ */

    for (q  = ngx_queue_head(&lir->rq_top);
         q != ngx_queue_sentinel(&lir->rq_top);
         q  = ngx_queue_next(q))
    {
        tr = ngx_queue_data(q, ngx_http_limit_traffic_rate_node_req_t, rq);

        if (tr->r == lircln->r) {
            /*
             * The log-phase handler already runs before pool destruction in
             * the normal path, so reaching here typically means the request
             * ended abnormally.  Free the entry and move on.
             */
            ngx_log_debug1(NGX_LOG_DEBUG_HTTP, lircln->shm_zone->shm.log, 0,
                           "limit traffic rate cleanup: freeing orphaned "
                           "queue entry for key %08XD", node->key);
            tr->r = NULL;
            ngx_queue_remove(q);
            ngx_slab_free_locked(shpool, tr);
            break;
        }
    }

    /* -- step 2: decrement the active-connection counter --------------- */

    if (lir->conn > 0) {
        lir->conn--;
    }

    /* -- step 3: free the rbtree node if no connections remain -------- */

    if (lir->conn == 0) {
        ngx_rbtree_delete(ctx->rbtree, node);
        ngx_slab_free_locked(shpool, node);

    } else {
        /* -- step 4: redistribute rate among surviving connections ----- */
        ngx_http_limit_traffic_rate_update_all(lir, lircf);
    }

    ngx_shmtx_unlock(&shpool->mutex);
}


/* -- module init (postconfiguration) --------------------------------------- */

static ngx_int_t
ngx_http_limit_traffic_rate_filter_init(ngx_conf_t *cf)
{
    ngx_http_handler_pt       *h;
    ngx_http_core_main_conf_t *cmcf;

    cmcf = ngx_http_conf_get_module_main_conf(cf, ngx_http_core_module);

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_PREACCESS_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }
    *h = ngx_http_limit_traffic_rate_filter_handler;

    h = ngx_array_push(&cmcf->phases[NGX_HTTP_LOG_PHASE].handlers);
    if (h == NULL) {
        return NGX_ERROR;
    }
    *h = ngx_http_limit_traffic_rate_filter_log_handler;

    ngx_http_next_body_filter = ngx_http_top_body_filter;
    ngx_http_top_body_filter  = ngx_http_limit_traffic_rate_body_filter;

    return NGX_OK;
}


/* -- location config lifecycle --------------------------------------------- */

static void *
ngx_http_limit_traffic_rate_filter_create_loc_conf(ngx_conf_t *cf)
{
    ngx_http_limit_traffic_rate_conf_t *conf;

    conf = ngx_pcalloc(cf->pool,
               sizeof(ngx_http_limit_traffic_rate_conf_t));
    if (conf == NULL) {
        return NGX_CONF_ERROR;
    }

    conf->limit_traffic_rate = NGX_CONF_UNSET_SIZE;
    conf->shm_zone           = NGX_CONF_UNSET_PTR;

    return conf;
}

static char *
ngx_http_limit_traffic_rate_filter_merge_loc_conf(ngx_conf_t *cf,
    void *parent, void *child)
{
    ngx_http_limit_traffic_rate_conf_t *prev = parent;
    ngx_http_limit_traffic_rate_conf_t *conf = child;

    ngx_conf_merge_size_value(conf->limit_traffic_rate,
                              prev->limit_traffic_rate, 0);
    ngx_conf_merge_ptr_value(conf->shm_zone, prev->shm_zone, NULL);

    return NGX_CONF_OK;
}


/* -- rbtree helpers --------------------------------------------------------- */

/*
 * Custom rbtree insertion value function.
 *
 * When two keys hash to the same value (collision), one is placed left and
 * the other right based on a lexicographic comparison of the actual key
 * bytes.  This keeps the tree balanced and allows exact-match lookup via
 * the do-while loop in the handler functions above.
 */
static void
ngx_http_limit_traffic_rate_filter_rbtree_insert_value(
    ngx_rbtree_node_t *temp, ngx_rbtree_node_t *node,
    ngx_rbtree_node_t *sentinel)
{
    ngx_rbtree_node_t                   **p;
    ngx_http_limit_traffic_rate_node_t  *lirn, *lirnt;

    for (;;) {

        if (node->key < temp->key) {
            p = &temp->left;

        } else if (node->key > temp->key) {
            p = &temp->right;

        } else { /* node->key == temp->key: hash collision — compare bytes */
            lirn  = (ngx_http_limit_traffic_rate_node_t *) &node->color;
            lirnt = (ngx_http_limit_traffic_rate_node_t *) &temp->color;

            p = (ngx_memn2cmp(lirn->data, lirnt->data,
                              lirn->len, lirnt->len) < 0)
                ? &temp->left : &temp->right;
        }

        if (*p == sentinel) {
            break;
        }

        temp = *p;
    }

    *p           = node;
    node->parent = temp;
    node->left   = sentinel;
    node->right  = sentinel;
    ngx_rbt_red(node);
}


/* -- shared memory zone initialisation ------------------------------------ */

static ngx_int_t
ngx_http_limit_traffic_rate_filter_init_zone(
    ngx_shm_zone_t *shm_zone, void *data)
{
    ngx_http_limit_traffic_rate_ctx_t *octx = data;

    /* C89: all declarations before statements. */
    size_t                             len;
    ngx_slab_pool_t                   *shpool;
    ngx_rbtree_node_t                 *sentinel;
    ngx_http_limit_traffic_rate_ctx_t *ctx;

    ctx = shm_zone->data;

    if (octx) {
        /*
         * Hot-reload path: nginx executes this callback with the old ctx
         * passed as data so we can reuse the existing rbtree instead of
         * reinitialising shared memory, provided the variable name matches.
         */
        if (ngx_strcmp(ctx->var.data, octx->var.data) != 0) {
            ngx_log_error(NGX_LOG_EMERG, shm_zone->shm.log, 0,
                          "limit_traffic_rate_filter \"%V\" uses variable "
                          "\"%V\" but previously used \"%V\"",
                          &shm_zone->shm.name, &ctx->var, &octx->var);
            return NGX_ERROR;
        }

        ctx->rbtree = octx->rbtree;
        return NGX_OK;
    }

    shpool = (ngx_slab_pool_t *) shm_zone->shm.addr;

    if (shm_zone->shm.exists) {
        /* Shared memory already initialised by another worker. */
        ctx->rbtree = shpool->data;
        return NGX_OK;
    }

    ctx->rbtree = ngx_slab_alloc(shpool, sizeof(ngx_rbtree_t));
    if (ctx->rbtree == NULL) {
        return NGX_ERROR;
    }

    shpool->data = ctx->rbtree;

    sentinel = ngx_slab_alloc(shpool, sizeof(ngx_rbtree_node_t));
    if (sentinel == NULL) {
        return NGX_ERROR;
    }

    ngx_rbtree_init(ctx->rbtree, sentinel,
                    ngx_http_limit_traffic_rate_filter_rbtree_insert_value);

    len = sizeof(" in limit_traffic_rate_filter \"\"") + shm_zone->shm.name.len;

    shpool->log_ctx = ngx_slab_alloc(shpool, len);
    if (shpool->log_ctx == NULL) {
        return NGX_ERROR;
    }

    ngx_sprintf(shpool->log_ctx, " in limit_traffic_rate_filter \"%V\"%Z",
                &shm_zone->shm.name);

    return NGX_OK;
}


/* -- directive parsing ------------------------------------------------------ */

/*
 * limit_traffic_rate_zone  <name>  <$variable>  <size>;
 *
 * Registers a named shared-memory zone keyed on a nginx variable.
 * value[0] = directive name
 * value[1] = zone name
 * value[2] = $variable  (must start with '$')
 * value[3] = zone size  (e.g. "32m")
 */
static char *
ngx_http_limit_traffic_rate_zone(ngx_conf_t *cf, ngx_command_t *cmd,
    void *conf)
{
    /* C89: all declarations before statements. */
    ssize_t                            n;
    ngx_str_t                         *value;
    ngx_shm_zone_t                    *shm_zone;
    ngx_http_limit_traffic_rate_ctx_t *ctx;

    value = cf->args->elts;

    if (value[2].data[0] != '$') {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid variable name \"%V\"", &value[2]);
        return NGX_CONF_ERROR;
    }

    value[2].len--;
    value[2].data++;

    ctx = ngx_pcalloc(cf->pool, sizeof(ngx_http_limit_traffic_rate_ctx_t));
    if (ctx == NULL) {
        return NGX_CONF_ERROR;
    }

    ctx->index = ngx_http_get_variable_index(cf, &value[2]);
    if (ctx->index == NGX_ERROR) {
        return NGX_CONF_ERROR;
    }

    ctx->var = value[2];

    n = ngx_parse_size(&value[3]);
    if (n == NGX_ERROR) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid size \"%V\" in limit_traffic_rate_zone",
                           &value[3]);
        return NGX_CONF_ERROR;
    }

    if (n < (ngx_int_t)(8 * ngx_pagesize)) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "limit_traffic_rate_zone \"%V\" is too small",
                           &value[1]);
        return NGX_CONF_ERROR;
    }

    shm_zone = ngx_shared_memory_add(cf, &value[1], n,
                   &ngx_http_limit_traffic_rate_filter_module);
    if (shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }

    if (shm_zone->data) {
        ctx = shm_zone->data;
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "limit_traffic_rate_zone \"%V\" is already bound "
                           "to variable \"%V\"", &value[1], &ctx->var);
        return NGX_CONF_ERROR;
    }

    shm_zone->init = ngx_http_limit_traffic_rate_filter_init_zone;
    shm_zone->data = ctx;

    return NGX_CONF_OK;
}


/*
 * limit_traffic_rate  <zone_name>  <rate>;
 *
 * Binds a zone to a location and sets the aggregate rate ceiling.
 * value[0] = directive name
 * value[1] = zone name
 * value[2] = rate (e.g. "20k")
 */
static char *
ngx_http_limit_traffic_rate(ngx_conf_t *cf, ngx_command_t *cmd, void *conf)
{
    ngx_http_limit_traffic_rate_conf_t *lircf = conf;

    /* C89: all declarations before statements. */
    ngx_int_t   n;
    ngx_str_t  *value;

    value = cf->args->elts;

    lircf->shm_zone = ngx_shared_memory_add(cf, &value[1], 0,
                          &ngx_http_limit_traffic_rate_filter_module);
    if (lircf->shm_zone == NULL) {
        return NGX_CONF_ERROR;
    }

    n = ngx_parse_size(&value[2]);
    if (n == NGX_ERROR) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "invalid rate \"%V\" in limit_traffic_rate",
                           &value[2]); /* fix: original incorrectly used &value[3] */
        return NGX_CONF_ERROR;
    }

    if (n <= 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "rate must be positive in "
                           "limit_traffic_rate \"%V\"", &value[2]);
        return NGX_CONF_ERROR;
    }

    lircf->limit_traffic_rate = n;

    return NGX_CONF_OK;
}
