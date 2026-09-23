#include "zstd_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef TB_NO_ZSTD

int32_t tb_zstd_decompress_file(const char *path, uint8_t **out, size_t *out_len) {
    (void)path;
    (void)out;
    (void)out_len;
    return -100;
}

void tb_zstd_free(void *p) { free(p); }

int32_t tb_zstd_unavailable(void) { return 1; }

#else

#include <zstd.h>

#define TB_IN_CHUNK (1u << 16)
#define TB_INITIAL_OUT (1u << 20)

int32_t tb_zstd_decompress_file(const char *path, uint8_t **out, size_t *out_len) {
    if (!path || !out || !out_len) return -1;

    FILE *f = fopen(path, "rb");
    if (!f) return -2;

    ZSTD_DStream *ds = ZSTD_createDStream();
    if (!ds) {
        fclose(f);
        return -3;
    }
    size_t init = ZSTD_initDStream(ds);
    if (ZSTD_isError(init)) {
        ZSTD_freeDStream(ds);
        fclose(f);
        return -4;
    }

    void *in_buf = malloc(TB_IN_CHUNK);
    size_t cap = TB_INITIAL_OUT;
    uint8_t *buf = malloc(cap);
    if (!in_buf || !buf) {
        free(in_buf);
        free(buf);
        ZSTD_freeDStream(ds);
        fclose(f);
        return -5;
    }

    ZSTD_inBuffer in = {in_buf, 0, 0};
    size_t len = 0;
    int32_t rc = 0;

    for (;;) {
        if (in.pos == in.size) {
            in.size = fread(in_buf, 1, TB_IN_CHUNK, f);
            in.pos = 0;
            if (in.size == 0) break; /* clean EOF */
        }

        if (len == cap) {
            size_t next = cap * 2;
            uint8_t *grown = realloc(buf, next);
            if (!grown) {
                rc = -6;
                break;
            }
            buf = grown;
            cap = next;
        }

        ZSTD_outBuffer outb = {buf + len, cap - len, 0};
        size_t ret = ZSTD_decompressStream(ds, &outb, &in);
        if (ZSTD_isError(ret)) {
            rc = -7;
            break;
        }
        len += outb.pos;

        if (outb.pos == 0 && in.pos == in.size && ret == 0) {
            /* Frame finished and the input chunk is drained: keep reading. */
            continue;
        }
    }

    free(in_buf);
    ZSTD_freeDStream(ds);
    int had_error = ferror(f);
    fclose(f);

    if (rc != 0 || had_error) {
        free(buf);
        return rc != 0 ? rc : -8;
    }

    *out = buf;
    *out_len = len;
    return 0;
}

void tb_zstd_free(void *p) { free(p); }

int32_t tb_zstd_unavailable(void) { return 0; }

#endif /* TB_NO_ZSTD */
