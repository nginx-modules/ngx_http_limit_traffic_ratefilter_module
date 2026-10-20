/*
 * ngx_http_limit_traffic_rate_filter_module.c
 *
 * Shares a configured download rate among active requests with the same
 * key (e.g. $remote_addr).  Each request receives an approximate equal
 * slice using the connection counter in shared memory.  Changes in that
 * counter become visible to existing requests at subsequent filter calls;
 * this is not a strict aggregate byte-budget limiter.
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
 * Pool cleanup record — lives in the request pool (per-worker heap).
 * Contains only values that are safe to access from the owning worker:
 *   shm_zone  — pointer into the shared-memory mapping (valid in all workers)
 *   node      — pointer inside the slab pool (valid in all workers)
 * Notably absent: ngx_http_request_t *r.  We do not need it; the cleanup
 * handler receives this struct as its argument and the request pool is still
 * alive at that point, but we identify the node via the stored pointer, not
 * by scanning a queue for a matching r.
 */
typedef struct {
    ngx_shm_zone_t    *shm_zone;
    ngx_rbtree_node_t *node;
    size_t             limit;
} ngx_http_limit_traffic_rate_cleanup_t;

/*
 * Red-black tree node payload, aliased from rbtree_node.color.
 * Contains ONLY data that is safe to share across worker processes:
 *   color     — rbtree bookkeeping (must be first, aliased from rbtree_node)
 *   len       — byte length of the key stored in data[]
 *   conn      — count of currently active connections for this key
 *   data[]    — the key bytes (e.g. the client IP string)
 *
 * There is no queue, no request pointer, no process-local address here.
 */
typedef struct {
    u_char   color;   /* MUST be first: aliased from ngx_rbtree_node_t.color */
    u_short  len;
    u_short  conn;    /* protected by shpool->mutex on every read/write       */
    u_char   data[1]; /* flexible array; actual allocation covers len bytes   */
} ngx_http_limit_traffic_rate_node_t;

typedef struct {
    ngx_rbtree_t  *rbtree;
    ngx_int_t      index;
    ngx_str_t      var;
} ngx_http_limit_traffic_rate_ctx_t;

typedef struct {
    size_t          limit_traffic_rate;
    ngx_shm_zone_t *shm_zone;
} ngx_http_limit_traffic_rate_conf_t;


/* -- module directives ------------------------------------------------------ */

static ngx_command_t ngx_http_limit_traffic_rate_filter_commands[] = {

    { ngx_string("limit_traffic_rate_zone"),
      NGX_HTTP_MAIN_CONF|NGX_CONF_TAKE3,
      ngx_http_limit_traffic_rate_zone,
      0, 0, NULL },

    { ngx_string("limit_traffic_rate"),
      NGX_HTTP_MAIN_CONF|NGX_HTTP_SRV_CONF|NGX_HTTP_LOC_CONF|NGX_CONF_TAKE2,
      ngx_http_limit_traffic_rate,
      NGX_HTTP_LOC_CONF_OFFSET, 0, NULL },

    ngx_null_command
};


static ngx_http_module_t ngx_http_limit_traffic_rate_filter_module_ctx = {
    NULL,
    ngx_http_limit_traffic_rate_filter_init,
    NULL, NULL,
    NULL, NULL,
    ngx_http_limit_traffic_rate_filter_create_loc_conf,
    ngx_http_limit_traffic_rate_filter_merge_loc_conf
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


/* -- shared rbtree lookup (internal, called with mutex held) --------------- */

/* A zero rate disables nginx's limiter. Never round a share down to zero. */
static size_t
ngx_http_limit_traffic_rate_share(size_t limit, u_short conn)
{
    size_t rate;

    rate = limit / conn;  /* caller holds the lock and checks conn != 0 */
    return rate ? rate : 1;
}


/*
 * Finds the rbtree node for (hash, data, len) and returns a pointer
 * to its payload, or NULL if not found. Caller must hold shpool->mutex.
 */
static ngx_http_limit_traffic_rate_node_t *
ngx_http_limit_traffic_rate_lookup(
    ngx_http_limit_traffic_rate_ctx_t *ctx,
    uint32_t hash, u_char *data, size_t len,
    ngx_rbtree_node_t **node_out)
{
    ngx_int_t                             rc;
    ngx_rbtree_node_t                    *node, *sentinel;
    ngx_http_limit_traffic_rate_node_t   *lir;

    node     = ctx->rbtree->root;
    sentinel = ctx->rbtree->sentinel;

    while (node != sentinel) {

        if (hash < node->key) { node = node->left;  continue; }
        if (hash > node->key) { node = node->right; continue; }

        do {
            lir = (ngx_http_limit_traffic_rate_node_t *) &node->color;
            rc  = ngx_memn2cmp(data, lir->data, len, (size_t) lir->len);

            if (rc == 0) {
                if (node_out != NULL) {
                    *node_out = node;
                }
                return lir;
            }

            node = (rc < 0) ? node->left : node->right;

        } while (node != sentinel && hash == node->key);

        break;
    }

    return NULL;
}


/* -- PREACCESS phase handler ------------------------------------------------ */

static ngx_int_t
ngx_http_limit_traffic_rate_filter_handler(ngx_http_request_t *r)
{
    /* C89: all declarations before statements. */
    size_t                                  len, n;
    uint32_t                                hash;
    ngx_slab_pool_t                        *shpool;
    ngx_rbtree_node_t                      *node;
    ngx_pool_cleanup_t                     *cln;
    ngx_http_variable_value_t              *vv;
    ngx_http_limit_traffic_rate_ctx_t      *ctx;
    ngx_http_limit_traffic_rate_node_t     *lir;
    ngx_http_limit_traffic_rate_conf_t     *lircf;
    ngx_http_limit_traffic_rate_cleanup_t  *lircln;

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
        ngx_log_error(NGX_LOG_WARN, r->connection->log, 0,
                      "limit_traffic_rate: \"%V\" variable value "
                      "exceeds 1024 bytes", &ctx->var);
        return NGX_DECLINED;
    }

    hash = ngx_crc32_short(vv->data, len);

    /*
     * Allocate the pool cleanup record before locking — pool allocation
     * must not happen while holding the shmtx spinlock.
     */
    cln = ngx_pool_cleanup_add(r->pool,
              sizeof(ngx_http_limit_traffic_rate_cleanup_t));
    if (cln == NULL) {
        return NGX_HTTP_INTERNAL_SERVER_ERROR;
    }

    shpool = (ngx_slab_pool_t *) lircf->shm_zone->shm.addr;

    ngx_shmtx_lock(&shpool->mutex);

    lir = ngx_http_limit_traffic_rate_lookup(ctx, hash, vv->data, len, &node);

    if (lir != NULL) {
        /*
         * Existing node: increment the connection counter and assign
         * the new per-connection rate to this request only.
         * Other workers' requests will refresh their own r->limit_rate
         * the next time their body filter runs.
         */
        if (lir->conn == (u_short) -1) {
            ngx_shmtx_unlock(&shpool->mutex);
            return NGX_HTTP_SERVICE_UNAVAILABLE;
        }

        lir->conn++;
        r->limit_rate = ngx_http_limit_traffic_rate_share(
                            lircf->limit_traffic_rate, lir->conn);

    } else {
        /*
         * No existing node: allocate one and set conn = 1.
         * This worker gets the full configured rate.
         */
        n = offsetof(ngx_rbtree_node_t, color)
          + offsetof(ngx_http_limit_traffic_rate_node_t, data)
          + len;

        node = ngx_slab_alloc_locked(shpool, n);
        if (node == NULL) {
            ngx_shmtx_unlock(&shpool->mutex);
            return NGX_HTTP_SERVICE_UNAVAILABLE;
        }

        lir        = (ngx_http_limit_traffic_rate_node_t *) &node->color;
        node->key  = hash;
        lir->len   = (u_short) len;
        lir->conn  = 1;

        ngx_memcpy(lir->data, vv->data, len);
        ngx_rbtree_insert(ctx->rbtree, node);

        r->limit_rate = lircf->limit_traffic_rate;
    }

    ngx_log_debug2(NGX_LOG_DEBUG_HTTP, r->connection->log, 0,
                   "limit traffic rate: %08XD conn=%d", node->key, lir->conn);

    ngx_shmtx_unlock(&shpool->mutex);

    cln->handler = ngx_http_limit_traffic_rate_filter_cleanup;
    lircln       = cln->data;

    lircln->shm_zone = lircf->shm_zone;
    lircln->node     = node;
    lircln->limit    = lircf->limit_traffic_rate;

    /* Mark our value as authoritative for the core write filter. */
    r->limit_rate_set = 1;

    /* Only registered requests may refresh their rate in the body filter. */
    ngx_http_set_ctx(r, lircln, ngx_http_limit_traffic_rate_filter_module);

    return NGX_DECLINED;
}


/* -- body filter: refresh r->limit_rate from the current conn count ------- */

/*
 * Refresh only requests registered in PREACCESS.  The request-pool cleanup
 * record is our per-request context and keeps the shared node allocated
 * until request teardown; dereference the node only under its slab mutex.
 * Recalculation happens on body-filter invocation, not synchronously on
 * every counter change in another worker.
 */
static ngx_int_t
ngx_http_limit_traffic_rate_body_filter(ngx_http_request_t *r, ngx_chain_t *in)
{
    ngx_slab_pool_t                        *shpool;
    ngx_http_limit_traffic_rate_node_t     *lir;
    ngx_http_limit_traffic_rate_cleanup_t  *lircln;

    lircln = ngx_http_get_module_ctx(r,
                 ngx_http_limit_traffic_rate_filter_module);
    if (lircln == NULL) {
        return ngx_http_next_body_filter(r, in);
    }

    shpool = (ngx_slab_pool_t *) lircln->shm_zone->shm.addr;
    ngx_shmtx_lock(&shpool->mutex);

    lir = (ngx_http_limit_traffic_rate_node_t *) &lircln->node->color;
    if (lir->conn != 0) {
        r->limit_rate = ngx_http_limit_traffic_rate_share(
                            lircln->limit, lir->conn);
        r->limit_rate_set = 1;
    }

    ngx_shmtx_unlock(&shpool->mutex);

    return ngx_http_next_body_filter(r, in);
}


/* -- cleanup handler ------------------------------------------------------- */

/*
 * Fires when r->pool is destroyed — after normal completion, timeout, or
 * client abort.  This is the single point of conn decrement; there is no
 * separate log-phase handler because there is no per-request slab entry
 * to free.
 */
static void
ngx_http_limit_traffic_rate_filter_cleanup(void *data)
{
    /* C89: all declarations before statements. */
    ngx_http_limit_traffic_rate_cleanup_t *lircln = data;

    ngx_slab_pool_t                       *shpool;
    ngx_rbtree_node_t                     *node;
    ngx_http_limit_traffic_rate_ctx_t     *ctx;
    ngx_http_limit_traffic_rate_node_t    *lir;

    ctx    = lircln->shm_zone->data;
    shpool = (ngx_slab_pool_t *) lircln->shm_zone->shm.addr;
    node   = lircln->node;
    lir    = (ngx_http_limit_traffic_rate_node_t *) &node->color;

    ngx_shmtx_lock(&shpool->mutex);

    ngx_log_debug2(NGX_LOG_DEBUG_HTTP, lircln->shm_zone->shm.log, 0,
                   "limit traffic rate cleanup: %08XD conn=%d",
                   node->key, lir->conn);

    if (lir->conn > 0) {
        lir->conn--;
    }

    if (lir->conn == 0) {
        ngx_rbtree_delete(ctx->rbtree, node);
        ngx_slab_free_locked(shpool, node);
    }

    ngx_shmtx_unlock(&shpool->mutex);
}


/* -- module init ----------------------------------------------------------- */

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

    ngx_http_next_body_filter = ngx_http_top_body_filter;
    ngx_http_top_body_filter  = ngx_http_limit_traffic_rate_body_filter;

    return NGX_OK;
}


/* -- location config ------------------------------------------------------- */

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


/* -- rbtree ---------------------------------------------------------------- */

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

        } else {
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


/* -- shared memory zone init ----------------------------------------------- */

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


/* -- directive parsing ----------------------------------------------------- */

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

    if (value[2].len < 2 || value[2].data[0] != '$') {
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
                           &value[2]);
        return NGX_CONF_ERROR;
    }

    if (n <= 0) {
        ngx_conf_log_error(NGX_LOG_EMERG, cf, 0,
                           "rate must be positive in limit_traffic_rate \"%V\"",
                           &value[2]);
        return NGX_CONF_ERROR;
    }

    lircf->limit_traffic_rate = n;

    return NGX_CONF_OK;
}
