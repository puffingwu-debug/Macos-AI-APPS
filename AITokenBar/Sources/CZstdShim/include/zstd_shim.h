#ifndef TB_ZSTD_SHIM_H
#define TB_ZSTD_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Decompresses a whole zstd file (including concatenated frames, which is what an
/// append-only log produces) into a freshly malloc'd buffer.
///
/// @param path      NUL-terminated filesystem path.
/// @param out       Receives a malloc'd buffer. Only written on success.
/// @param out_len   Receives the number of decompressed bytes. Only written on success.
/// @return 0 on success, negative error code otherwise.
int32_t tb_zstd_decompress_file(const char *path, uint8_t **out, size_t *out_len);

/// Frees a buffer returned by tb_zstd_decompress_file.
void tb_zstd_free(void *p);

/// Non-zero when the shim was compiled without zstd support.
int32_t tb_zstd_unavailable(void);

#ifdef __cplusplus
}
#endif

#endif /* TB_ZSTD_SHIM_H */
