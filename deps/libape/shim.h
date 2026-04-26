#ifndef VALIDATE_APE_SHIM_H
#define VALIDATE_APE_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Decode every frame of the APE bitstream in `data` and return integrity status.
 *
 * Result codes:
 *    0 = success — all frames decoded, all per-frame CRCs verified, MD5 matched
 *        (when present in the descriptor).
 *  -1 = open failed (corrupt / unsupported header).
 *  -2 = mid-stream decode failure (bitstream parse error).
 *  -3 = per-frame CRC32-over-decoded-PCM mismatch (the integrity bit we care about).
 *  -4 = descriptor MD5-over-decoded-PCM mismatch.
 *  -5 = sample count mismatch / truncation.
 *  -6 = generic failure (out of memory, unexpected internal error).
 *
 * `total_blocks_out` (optional, may be NULL) receives the number of blocks
 * successfully decoded. `file_version_out` (optional) receives the APE
 * file version (e.g. 3990 for v3.99).
 */
int validate_ape_decode_check(
	const uint8_t *data,
	size_t data_len,
	int64_t *total_blocks_out,
	int *file_version_out
);

#ifdef __cplusplus
}
#endif

#endif
