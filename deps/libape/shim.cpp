// validate/libape thin C shim around the upstream Monkey's Audio SDK
// (https://monkeysaudio.com/, BSD-3 since 2023). This wrapper takes a
// buffer of APE bytes, decodes every frame, and returns whether the
// per-frame CRC32 (computed over decoded PCM samples per
// APEDecompressCore.cpp::EndFrame) matches. That is the only honest
// path to byte-deep APE validation — structural rigor cannot reach it.
//
// We use CMemoryIO + CreateIAPEDecompressEx so the library never
// touches the filesystem. The decode loop discards PCM (we don't
// need to play audio); we just look at GetData's return code:
// ERROR_INVALID_CHECKSUM (1009) surfaces per-frame CRC mismatch.
//
// Truncation manifests as nBytesLeft != 0 inside the unpack core,
// which propagates as a decode error and stops the loop short of
// total_blocks; we treat any short decode as a validation failure.

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>

#include "All.h"
#include "MACLib.h"
#include "MemoryIO.h"

#include "shim.h"

namespace
{

constexpr int64_t kBlocksPerCall = 4096;

}

extern "C" int validate_ape_decode_check(
	const uint8_t *data,
	size_t data_len,
	int64_t *total_blocks_out,
	int *file_version_out)
{
	if (total_blocks_out) *total_blocks_out = 0;
	if (file_version_out) *file_version_out = 0;

	if (data == nullptr || data_len < 64) return -1;

	// CMemoryIO takes a non-const buffer pointer (legacy API), but it
	// only reads in our usage. Casting away const is safe — the only
	// write paths are gated by Write/Create/Delete which we never
	// call on a decompressor.
	APE::CMemoryIO io(const_cast<unsigned char *>(data),
		static_cast<int>(data_len > 0x7fffffff ? 0x7fffffff : data_len));

	int err = ERROR_SUCCESS;
	APE::IAPEDecompress *dec = ::CreateIAPEDecompressEx(&io, &err);
	if (dec == nullptr || err != ERROR_SUCCESS)
	{
		if (dec) delete dec;
		return -1;
	}

	int rc = 0;

	const int64_t total_blocks = dec->GetInfo(APE::IAPEDecompress::APE_DECOMPRESS_TOTAL_BLOCKS);
	const int block_align = static_cast<int>(dec->GetInfo(APE::IAPEDecompress::APE_INFO_BLOCK_ALIGN));
	const int file_version = static_cast<int>(dec->GetInfo(APE::IAPEDecompress::APE_INFO_FILE_VERSION));
	if (file_version_out) *file_version_out = file_version;

	if (block_align <= 0 || block_align > 32) {
		delete dec;
		return -1;
	}

	const size_t buf_size = static_cast<size_t>(kBlocksPerCall) * static_cast<size_t>(block_align);
	unsigned char *pcm = static_cast<unsigned char *>(::malloc(buf_size));
	if (pcm == nullptr) {
		delete dec;
		return -6;
	}

	int64_t decoded = 0;
	while (decoded < total_blocks) {
		int64_t got = 0;
		const int dr = dec->GetData(pcm, kBlocksPerCall, &got, nullptr);
		if (dr != ERROR_SUCCESS) {
			if (dr == ERROR_INVALID_CHECKSUM) {
				rc = -3;
			} else {
				rc = -2;
			}
			break;
		}
		if (got <= 0) break;
		decoded += got;
	}

	if (rc == 0 && decoded != total_blocks) {
		rc = -5;
	}

	if (total_blocks_out) *total_blocks_out = decoded;

	::free(pcm);
	delete dec;
	return rc;
}
