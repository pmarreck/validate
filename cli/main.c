/* Enable POSIX extensions (strdup, etc.) on strict C99/C11 systems like musl */
#define _POSIX_C_SOURCE 200809L

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/stat.h>
#include <dirent.h>
#include <time.h>
#include <math.h>
#include <stdarg.h>
#include <stdatomic.h>
#if defined(_WIN32)
#include <windows.h>
#include <psapi.h>
#include <io.h>
#define isatty _isatty
#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2
#define PATH_SEP '\\'
#define IS_PATH_SEP(c) ((c) == '/' || (c) == '\\')
#else
#include <unistd.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <pthread.h>
#define PATH_SEP '/'
#define IS_PATH_SEP(c) ((c) == '/')
#endif
#if defined(__APPLE__)
#include <mach/mach.h>
#endif
#include "validate_core.h"

/* ========== Self-Hash: SHA-256 of the running binary ========== */
/* Computed at startup, written as the first line of every output file
 * to prove which binary version produced the output. */
static char g_self_hash[65] = {0}; /* 64 hex chars + null */

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

/* Minimal SHA-256 implementation (RFC 6234) for self-hashing */
static const uint32_t sha256_k[64] = {
	0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
	0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
	0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
	0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
	0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
	0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
	0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
	0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

#define SHA256_RR(x,n) (((x)>>(n))|((x)<<(32-(n))))

static void sha256_transform(uint32_t state[8], const uint8_t block[64]) {
	uint32_t w[64], a,b,c,d,e,f,g,h,t1,t2;
	for (int i=0;i<16;i++) w[i]=(uint32_t)block[i*4]<<24|(uint32_t)block[i*4+1]<<16|(uint32_t)block[i*4+2]<<8|block[i*4+3];
	for (int i=16;i<64;i++) {uint32_t s0=SHA256_RR(w[i-15],7)^SHA256_RR(w[i-15],18)^(w[i-15]>>3);uint32_t s1=SHA256_RR(w[i-2],17)^SHA256_RR(w[i-2],19)^(w[i-2]>>10);w[i]=w[i-16]+s0+w[i-7]+s1;}
	a=state[0];b=state[1];c=state[2];d=state[3];e=state[4];f=state[5];g=state[6];h=state[7];
	for (int i=0;i<64;i++){t1=h+(SHA256_RR(e,6)^SHA256_RR(e,11)^SHA256_RR(e,25))+((e&f)^(~e&g))+sha256_k[i]+w[i];t2=(SHA256_RR(a,2)^SHA256_RR(a,13)^SHA256_RR(a,22))+((a&b)^(a&c)^(b&c));h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;}
	state[0]+=a;state[1]+=b;state[2]+=c;state[3]+=d;state[4]+=e;state[5]+=f;state[6]+=g;state[7]+=h;
}

static void compute_self_hash(const char* argv0) {
	char exe_path[4096] = {0};
#if defined(__linux__)
	ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path)-1);
	if (len <= 0) strncpy(exe_path, argv0, sizeof(exe_path)-1);
	else exe_path[len] = '\0';
#elif defined(__APPLE__)
	uint32_t size = sizeof(exe_path);
	if (_NSGetExecutablePath(exe_path, &size) != 0) strncpy(exe_path, argv0, sizeof(exe_path)-1);
#elif defined(_WIN32)
	GetModuleFileNameA(NULL, exe_path, sizeof(exe_path));
#else
	strncpy(exe_path, argv0, sizeof(exe_path)-1);
#endif

	FILE* f = fopen(exe_path, "rb");
	if (!f) { snprintf(g_self_hash, sizeof(g_self_hash), "(unable to hash self)"); return; }

	uint32_t state[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
	uint8_t buf[4096];
	uint64_t total = 0;
	size_t n;
	while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
		size_t off = 0;
		while (off + 64 <= n) { sha256_transform(state, buf + off); off += 64; total += 64; }
		if (off < n) {
			/* Handle partial block at end of chunk — accumulate */
			uint8_t partial[64] = {0};
			size_t remaining = n - off;
			memcpy(partial, buf + off, remaining);
			/* Check if more data follows */
			size_t n2 = fread(buf, 1, 64 - remaining, f);
			memcpy(partial + remaining, buf, n2);
			total += remaining + n2;
			if (remaining + n2 == 64) { sha256_transform(state, partial); }
			else {
				/* Final padding */
				size_t last = remaining + n2;
				partial[last] = 0x80;
				if (last >= 56) { sha256_transform(state, partial); memset(partial, 0, 64); }
				uint64_t bits = total * 8;
				for (int i=0;i<8;i++) partial[63-i] = (uint8_t)(bits>>(i*8));
				sha256_transform(state, partial);
				goto done;
			}
		}
	}
	{ /* Final padding for block-aligned data */
		uint8_t pad[64] = {0};
		pad[0] = 0x80;
		if ((total % 64) >= 56) { sha256_transform(state, pad); memset(pad, 0, 64); }
		uint64_t bits = total * 8;
		for (int i=0;i<8;i++) pad[63-i] = (uint8_t)(bits>>(i*8));
		sha256_transform(state, pad);
	}
done:
	fclose(f);
	for (int i=0;i<8;i++) snprintf(g_self_hash + i*8, 9, "%08x", state[i]);
}

/* ========== Self-Integrity Verification ========== */
/* The binary may have a 48-byte integrity trailer appended by the build:
 *   "VALIDATE_INTEGRITY" (16 bytes) + SHA-256 (32 bytes raw)
 * If present, verify the hash of everything before the trailer. */
#define INTEGRITY_MARKER "VALIDATE_INTEGRITY"
#define INTEGRITY_MARKER_LEN 18
#define INTEGRITY_TRAILER_LEN (INTEGRITY_MARKER_LEN + 32) /* 50 bytes */

static int g_integrity_verified = 0;  /* 1=passed, -1=failed, 0=no trailer */

/* Compute SHA-256 of first `limit` bytes of a file, result in raw[32] */
static void sha256_file_range(const char* path, uint64_t limit, uint8_t raw[32]) {
	FILE* f = fopen(path, "rb");
	if (!f) { memset(raw, 0, 32); return; }

	uint32_t state[8] = {0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
	uint8_t buf[4096];
	uint64_t total = 0;
	while (total < limit) {
		size_t to_read = sizeof(buf);
		if (total + to_read > limit) to_read = (size_t)(limit - total);
		size_t n = fread(buf, 1, to_read, f);
		if (n == 0) break;
		size_t off = 0;
		while (off + 64 <= n) { sha256_transform(state, buf + off); off += 64; total += 64; }
		if (off < n) {
			uint8_t partial[64] = {0};
			size_t remaining = n - off;
			memcpy(partial, buf + off, remaining);
			total += remaining;
			size_t need = 64 - remaining;
			if (total < limit && need > 0) {
				size_t can = (total + need > limit) ? (size_t)(limit - total) : need;
				size_t n2 = fread(partial + remaining, 1, can, f);
				total += n2;
				remaining += n2;
			}
			if (remaining == 64) { sha256_transform(state, partial); }
			else {
				partial[remaining] = 0x80;
				if (remaining >= 56) { sha256_transform(state, partial); memset(partial, 0, 64); }
				uint64_t bits = total * 8;
				for (int i=0;i<8;i++) partial[63-i] = (uint8_t)(bits>>(i*8));
				sha256_transform(state, partial);
				goto hash_done;
			}
		}
	}
	{ uint8_t pad[64]={0}; pad[0]=0x80;
	  if((total%64)>=56){sha256_transform(state,pad);memset(pad,0,64);}
	  uint64_t bits=total*8;
	  for(int i=0;i<8;i++)pad[63-i]=(uint8_t)(bits>>(i*8));
	  sha256_transform(state,pad);
	}
hash_done:
	fclose(f);
	for (int i = 0; i < 8; i++) {
		raw[i*4]   = (uint8_t)(state[i] >> 24);
		raw[i*4+1] = (uint8_t)(state[i] >> 16);
		raw[i*4+2] = (uint8_t)(state[i] >> 8);
		raw[i*4+3] = (uint8_t)(state[i]);
	}
}

static void verify_self_integrity(const char* argv0) {
	char exe_path[4096] = {0};
#if defined(__linux__)
	ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path)-1);
	if (len <= 0) strncpy(exe_path, argv0, sizeof(exe_path)-1);
	else exe_path[len] = '\0';
#elif defined(__APPLE__)
	uint32_t size = sizeof(exe_path);
	if (_NSGetExecutablePath(exe_path, &size) != 0) strncpy(exe_path, argv0, sizeof(exe_path)-1);
#elif defined(_WIN32)
	GetModuleFileNameA(NULL, exe_path, sizeof(exe_path));
#else
	strncpy(exe_path, argv0, sizeof(exe_path)-1);
#endif

	/* Get file size */
	FILE* f = fopen(exe_path, "rb");
	if (!f) {
		fprintf(stderr, "\033[1;31mFATAL: Cannot open own executable for integrity check: %s\033[0m\n", exe_path);
		exit(1);
	}
	fseek(f, 0, SEEK_END);
	long file_size = ftell(f);
	if (file_size < INTEGRITY_TRAILER_LEN + 1024) {
		fclose(f);
		fprintf(stderr, "\033[1;31mFATAL: Binary too small to contain integrity trailer — unsigned or truncated\033[0m\n");
		exit(1);
	}

	/* Read the trailer */
	uint8_t trailer[INTEGRITY_TRAILER_LEN];
	fseek(f, file_size - INTEGRITY_TRAILER_LEN, SEEK_SET);
	if (fread(trailer, 1, INTEGRITY_TRAILER_LEN, f) != INTEGRITY_TRAILER_LEN) {
		fclose(f);
		fprintf(stderr, "\033[1;31mFATAL: Cannot read integrity trailer\033[0m\n");
		exit(1);
	}
	fclose(f);

	/* Check for marker */
	if (memcmp(trailer, INTEGRITY_MARKER, INTEGRITY_MARKER_LEN) != 0) {
		fprintf(stderr, "\033[1;31mFATAL: No integrity trailer — this binary was not signed.\033[0m\n");
		fprintf(stderr, "All builds must be signed. Use ./build or nix build, not raw zig build.\n");
		exit(1);
	}

	/* Compute SHA-256 of everything before the trailer */
	uint8_t computed[32];
	sha256_file_range(exe_path, (uint64_t)(file_size - INTEGRITY_TRAILER_LEN), computed);

	/* Compare */
	const uint8_t* expected = trailer + INTEGRITY_MARKER_LEN;
	if (memcmp(computed, expected, 32) == 0) {
		g_integrity_verified = 1;
	} else {
		fprintf(stderr, "\033[1;31mFATAL: Binary integrity check FAILED — this executable may be corrupted or tampered with!\033[0m\n");
		fprintf(stderr, "  Expected: ");
		for (int i=0;i<32;i++) fprintf(stderr, "%02x", expected[i]);
		fprintf(stderr, "\n  Computed: ");
		for (int i=0;i<32;i++) fprintf(stderr, "%02x", computed[i]);
		fprintf(stderr, "\n");
		exit(1);
	}
}

/* Write the self-hash header to a FILE* stream */
static void write_self_hash(FILE* f) {
	if (g_self_hash[0] && f) {
		fprintf(f, "# validate sha256:%s\n", g_self_hash);
		fflush(f);
	}
}

/* ========== Multi-Output Destination System ========== */
/*
 * Supports colon-delimited output destinations for *_OUT environment variables.
 * Special tokens: @stdout, @stderr
 * Windows-aware parsing: Don't split on colons in C:\ style paths
 */

/* File output mode: "w" (overwrite, default) or "a" (append with --append) */
static const char* g_file_open_mode = "w";

#define MAX_OUTPUT_DESTINATIONS 8

typedef struct {
	FILE* handles[MAX_OUTPUT_DESTINATIONS];
	int count;
	int owns_handle[MAX_OUTPUT_DESTINATIONS];  /* 1 if we opened it (need to close) */
	int muted;  /* 1 if @null was specified - no output at all */
} output_dest_t;

static output_dest_t g_ok_out;
static output_dest_t g_warn_out;
static output_dest_t g_fail_out;
static output_dest_t g_unknown_out;
static output_dest_t g_slow_out;
static output_dest_t g_debug_out;
static output_dest_t g_begin_out;

/* RTL bidirectional text support */
static int g_rtl_enabled = 0;
static const char* RLM = "\xE2\x80\x8F"; /* U+200F Right-to-Left Mark (UTF-8) */

/* Mutex to synchronize output and TUI rendering */
#if defined(_WIN32)
static CRITICAL_SECTION g_output_lock;
static int g_output_lock_initialized = 0;
#else
static pthread_mutex_t g_output_lock = PTHREAD_MUTEX_INITIALIZER;
#endif

/* Forward declarations for color variables (defined later) */
static const char* COLOR_YELLOW;

static void output_dest_init(output_dest_t* dest) {
	dest->count = 0;
	dest->muted = 0;
	for (int i = 0; i < MAX_OUTPUT_DESTINATIONS; i++) {
		dest->handles[i] = NULL;
		dest->owns_handle[i] = 0;
	}
}

static void output_dest_add(output_dest_t* dest, FILE* handle, int owns) {
	if (dest->count >= MAX_OUTPUT_DESTINATIONS) return;
	dest->handles[dest->count] = handle;
	dest->owns_handle[dest->count] = owns;
	dest->count++;
}

static void output_dest_close(output_dest_t* dest) {
	for (int i = 0; i < dest->count; i++) {
		if (dest->owns_handle[i] && dest->handles[i]) {
			fclose(dest->handles[i]);
		}
		dest->handles[i] = NULL;
		dest->owns_handle[i] = 0;
	}
	dest->count = 0;
}

/* Check if position is at a Windows drive letter (e.g., "C:" in "C:\path") */
static int is_windows_drive_colon(const char* spec, const char* colon_pos) {
	/* Must have exactly one character before colon */
	if (colon_pos - spec != 1) return 0;
	/* Must be a letter */
	char c = spec[0];
	if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))) return 0;
	/* Must have backslash or slash after colon (or end of string for bare "C:") */
	char next = colon_pos[1];
	return (next == '\\' || next == '/' || next == '\0');
}

/* Parse a single destination token and add to dest */
static int parse_single_dest(const char* token, size_t len, output_dest_t* dest) {
	if (len == 0) return 0;  /* Skip empty tokens */

	/* Check for special tokens */
	if (len == 5 && strncmp(token, "@null", 5) == 0) {
		/* @null must appear alone - mark as muted and don't add any handles */
		if (dest->count > 0) {
			fprintf(stderr, "Error: @null must be the only output destination\n");
			return -1;
		}
		dest->muted = 1;
		return 0;
	}
	/* Error if trying to add destinations to a muted output */
	if (dest->muted) {
		fprintf(stderr, "Error: @null must be the only output destination\n");
		return -1;
	}
	if (len == 7 && strncmp(token, "@stdout", 7) == 0) {
		output_dest_add(dest, stdout, 0);
		return 0;
	}
	if (len == 7 && strncmp(token, "@stderr", 7) == 0) {
		output_dest_add(dest, stderr, 0);
		return 0;
	}

	/* It's a file path - need to null-terminate for fopen */
	char* path = (char*)malloc(len + 1);
	if (!path) return -1;
	memcpy(path, token, len);
	path[len] = '\0';

	FILE* f = fopen(path, g_file_open_mode);
	if (!f) {
		fprintf(stderr, "%sWarning: failed to open output path: %s (%s)\n",
				COLOR_YELLOW ? COLOR_YELLOW : "", path, strerror(errno));
		free(path);
		return -1;
	}
	free(path);
	/* Write self-hash as first line for provenance tracking */
	write_self_hash(f);
	output_dest_add(dest, f, 1);
	return 0;
}

/* Parse colon-delimited output specification */
static int parse_output_spec(const char* spec, output_dest_t* dest) {
	if (!spec || spec[0] == '\0') return 0;

	const char* start = spec;
	const char* p = spec;

	while (*p) {
		if (*p == ':') {
			/* Check if this is a Windows drive letter */
			if (start == spec && is_windows_drive_colon(start, p)) {
				/* Skip this colon, it's part of a Windows path */
				p++;
				continue;
			}
			/* Also check for drive letter in middle of spec (after another path) */
			if (p > start && p - start >= 1) {
				const char* potential_drive = p - 1;
				/* If we're at X: where X is letter and next is \ or /, skip */
				if (potential_drive >= start &&
					((potential_drive[0] >= 'A' && potential_drive[0] <= 'Z') ||
					 (potential_drive[0] >= 'a' && potential_drive[0] <= 'z')) &&
					(potential_drive == start || potential_drive[-1] == ':') &&
					(p[1] == '\\' || p[1] == '/')) {
					p++;
					continue;
				}
			}

			/* This is a real delimiter */
			if (parse_single_dest(start, p - start, dest) != 0) {
				/* Continue despite errors - best effort */
			}
			start = p + 1;
		}
		p++;
	}

	/* Handle last token */
	if (start < p) {
		parse_single_dest(start, p - start, dest);
	}

	return 0;
}

/* Write formatted output to all destinations */
static void write_to_outputs(output_dest_t* dest, const char* fmt, ...) {
	va_list args;
	for (int i = 0; i < dest->count; i++) {
		if (dest->handles[i]) {
			va_start(args, fmt);
			vfprintf(dest->handles[i], fmt, args);
			va_end(args);
			fflush(dest->handles[i]);
		}
	}
}

/* Write string without formatting (for pre-formatted output) */
static void write_str_to_outputs(output_dest_t* dest, const char* str) {
	for (int i = 0; i < dest->count; i++) {
		if (dest->handles[i]) {
			fputs(str, dest->handles[i]);
			fflush(dest->handles[i]);
		}
	}
}

/* ========== KV-US-RS Parser ========== */
/*
 * Simple parser for KV-US-RS format (Key-Value with Unit/Record Separators).
 * Format: key1<US>value1<RS>key2<US>value2<RS>...
 * Where <US> = 0x1F, <RS> = 0x1E
 */

/* Stateful parser for iterating through all key-value pairs.
 * Used for rich metadata extraction where we need to enumerate
 * all returned fields rather than look up specific keys. */
typedef struct {
	const char* data;      /* Original string (not owned) */
	const char* pos;       /* Current position */
} kv_parser_t;

__attribute__((unused))
static void kv_parser_init(kv_parser_t* parser, const char* data) {
	parser->data = data;
	parser->pos = data;
}

/* Find a value by key. Returns pointer to value (within data), or NULL if not found.
 * Sets *value_len to the length of the value. */
static const char* kv_find(const char* data, const char* key, size_t* value_len) {
	if (!data || !key) return NULL;
	size_t key_len = strlen(key);
	const char* p = data;

	while (*p) {
		/* Find end of key (US or end of string) */
		const char* key_end = p;
		while (*key_end && *key_end != VALIDATE_US && *key_end != VALIDATE_RS) {
			key_end++;
		}

		size_t this_key_len = key_end - p;

		/* Check if this is our key */
		if (this_key_len == key_len && memcmp(p, key, key_len) == 0) {
			/* Found it! Value starts after US */
			if (*key_end == VALIDATE_US) {
				const char* value_start = key_end + 1;
				const char* value_end = value_start;
				while (*value_end && *value_end != VALIDATE_RS) {
					value_end++;
				}
				if (value_len) *value_len = value_end - value_start;
				return value_start;
			}
			/* Key with no value (shouldn't happen in well-formed data) */
			if (value_len) *value_len = 0;
			return key_end;
		}

		/* Skip to next record */
		p = key_end;
		if (*p == VALIDATE_US) {
			/* Skip value */
			p++;
			while (*p && *p != VALIDATE_RS) p++;
		}
		if (*p == VALIDATE_RS) p++;
	}

	return NULL;
}

/* Get string value, copying to provided buffer. Returns 0 on success. */
static int kv_get_str(const char* data, const char* key, char* buf, size_t buf_size) {
	size_t value_len = 0;
	const char* value = kv_find(data, key, &value_len);
	if (!value) {
		if (buf_size > 0) buf[0] = '\0';
		return -1;
	}
	size_t copy_len = (value_len < buf_size - 1) ? value_len : buf_size - 1;
	memcpy(buf, value, copy_len);
	buf[copy_len] = '\0';
	return 0;
}

/* Get boolean value. Returns 0 (false) or 1 (true). */
static int kv_get_bool(const char* data, const char* key) {
	size_t value_len = 0;
	const char* value = kv_find(data, key, &value_len);
	if (!value || value_len == 0) return 0;
	/* Falsy: "F", "0", empty */
	if (value_len == 1 && (value[0] == 'F' || value[0] == '0')) return 0;
	/* Everything else is truthy */
	return 1;
}

/* Get uint64 value. Returns 0 on error or if not found. */
static uint64_t kv_get_u64(const char* data, const char* key) {
	size_t value_len = 0;
	const char* value = kv_find(data, key, &value_len);
	if (!value || value_len == 0) return 0;

	/* Copy to temp buffer for strtoul */
	char buf[32];
	size_t copy_len = (value_len < sizeof(buf) - 1) ? value_len : sizeof(buf) - 1;
	memcpy(buf, value, copy_len);
	buf[copy_len] = '\0';

	/* Support hex (0x) and binary (0b) */
	if (copy_len >= 2 && buf[0] == '0' && buf[1] == 'x') {
		return strtoull(buf + 2, NULL, 16);
	}
	if (copy_len >= 2 && buf[0] == '0' && buf[1] == 'b') {
		return strtoull(buf + 2, NULL, 2);
	}
	return strtoull(buf, NULL, 10);
}

/* Get int64 value. Returns 0 on error or if not found. */
static int64_t kv_get_i64(const char* data, const char* key) {
	size_t value_len = 0;
	const char* value = kv_find(data, key, &value_len);
	if (!value || value_len == 0) return 0;

	char buf[32];
	size_t copy_len = (value_len < sizeof(buf) - 1) ? value_len : sizeof(buf) - 1;
	memcpy(buf, value, copy_len);
	buf[copy_len] = '\0';

	return strtoll(buf, NULL, 10);
}

/* ========== File Path Collection ========== */

typedef struct {
	char** paths;
	uint32_t* ids;
	size_t* sizes;      /* File sizes in bytes */
	size_t count;
	size_t capacity;
	size_t max_files;   /* 0 = unlimited */
	size_t total_bytes; /* Sum of all file sizes */
} path_list_t;

static int path_list_init(path_list_t* list, size_t initial_capacity, size_t max_files) {
	list->paths = (char**)malloc(initial_capacity * sizeof(char*));
	list->ids = (uint32_t*)malloc(initial_capacity * sizeof(uint32_t));
	list->sizes = (size_t*)malloc(initial_capacity * sizeof(size_t));
	if (!list->paths || !list->ids || !list->sizes) {
		free(list->paths);
		free(list->ids);
		free(list->sizes);
		return -1;
	}
	list->count = 0;
	list->capacity = initial_capacity;
	list->max_files = max_files;
	list->total_bytes = 0;
	return 0;
}

static void path_list_free(path_list_t* list) {
	for (size_t i = 0; i < list->count; i++) {
		free(list->paths[i]);
	}
	free(list->paths);
	free(list->ids);
	free(list->sizes);
	list->paths = NULL;
	list->ids = NULL;
	list->sizes = NULL;
	list->count = 0;
	list->capacity = 0;
	list->total_bytes = 0;
}

/* Progress display for file enumeration */
static int g_show_enum_progress = 0;
static size_t g_last_progress_count = 0;

static void show_enum_progress(size_t count) {
	if (!g_show_enum_progress) return;
	/* Only update every 100 files or if count changed significantly to reduce flicker */
	if (count - g_last_progress_count >= 100 || count < 100) {
		fprintf(stderr, "\r");
		fprintf(stderr, validate_tr(VALIDATE_STR_SCANNING_FILES_FOUND), count);
		fflush(stderr);
		g_last_progress_count = count;
	}
}

static void finish_enum_progress(void) {
	if (!g_show_enum_progress) return;
	/* Clear the progress line */
	fprintf(stderr, "\r\033[K");
	fflush(stderr);
	g_last_progress_count = 0;
}

static int path_list_add(path_list_t* list, const char* path, size_t file_size) {
	if (list->max_files > 0 && list->count >= list->max_files) {
		return 0;  /* Silently stop adding (hit limit) */
	}
	if (list->count >= list->capacity) {
		size_t new_capacity = list->capacity * 2;
		char** new_paths = (char**)realloc(list->paths, new_capacity * sizeof(char*));
		uint32_t* new_ids = (uint32_t*)realloc(list->ids, new_capacity * sizeof(uint32_t));
		size_t* new_sizes = (size_t*)realloc(list->sizes, new_capacity * sizeof(size_t));
		if (!new_paths || !new_ids || !new_sizes) return -1;
		list->paths = new_paths;
		list->ids = new_ids;
		list->sizes = new_sizes;
		list->capacity = new_capacity;
	}
	list->paths[list->count] = strdup(path);
	if (!list->paths[list->count]) return -1;
	list->ids[list->count] = (uint32_t)list->count;
	list->sizes[list->count] = file_size;
	list->total_bytes += file_size;
	list->count++;
	show_enum_progress(list->count);
	return 0;
}

/* Recursive directory enumeration */
static int enumerate_directory(const char* dir_path, path_list_t* list);

/* Helper to check if path ends with a suffix */
static int ends_with(const char* path, size_t len, const char* suffix) {
	size_t suffix_len = strlen(suffix);
	if (len < suffix_len) return 0;
	return strcmp(path + len - suffix_len, suffix) == 0;
}

/* Check if a path is a bundle directory that should be
 * validated as a single unit rather than recursed into.
 * Bundles: .git, .app, .framework, .bundle */
static int is_bundle_directory(const char* path) {
	size_t len = strlen(path);

	/* Check for .git (special case: must be standalone component) */
	if (len >= 4 && ends_with(path, len, ".git")) {
		/* Either exactly ".git" or ends with "/.git" */
		if (len == 4 || path[len - 5] == '/') {
			return 1;
		}
	}

	/* macOS bundles - directory extensions (all use Contents/ structure) */
	if (ends_with(path, len, ".app")) return 1;
	if (ends_with(path, len, ".framework")) return 1;
	if (ends_with(path, len, ".bundle")) return 1;
	if (ends_with(path, len, ".kext")) return 1;
	if (ends_with(path, len, ".prefPane")) return 1;
	if (ends_with(path, len, ".plugin")) return 1;
	if (ends_with(path, len, ".appex")) return 1;
	if (ends_with(path, len, ".xpc")) return 1;
	if (ends_with(path, len, ".qlgenerator")) return 1;
	if (ends_with(path, len, ".mdimporter")) return 1;
	if (ends_with(path, len, ".saver")) return 1;
	if (ends_with(path, len, ".component")) return 1;
	if (ends_with(path, len, ".driver")) return 1;

	return 0;
}

/* Check if a directory is a BagIt bag (contains bagit.txt) */
static int is_bagit_directory(const char* path) {
	size_t len = strlen(path);
	size_t bagit_len = len + 11; /* /bagit.txt\0 */
	char* bagit_path = (char*)malloc(bagit_len);
	if (!bagit_path) return 0;
	snprintf(bagit_path, bagit_len, "%s/bagit.txt", path);
	struct stat st;
	int result = (stat(bagit_path, &st) == 0 && S_ISREG(st.st_mode));
	free(bagit_path);
	return result;
}

static int enumerate_path(const char* path, path_list_t* list) {
	struct stat st;
	if (stat(path, &st) != 0) {
		/* Skip inaccessible files (broken symlinks, permission denied, etc.)
		 * rather than failing the entire enumeration */
		return 0;
	}

	if (S_ISREG(st.st_mode)) {
		return path_list_add(list, path, (size_t)st.st_size);
	} else if (S_ISDIR(st.st_mode)) {
		/* Check if this is a bundle directory (e.g., .git) */
		if (is_bundle_directory(path)) {
			/* Add bundle directory as a single validation item - don't recurse */
			return path_list_add(list, path, (size_t)st.st_size);
		}
		/* Check if this is a BagIt bag (contains bagit.txt) */
		if (is_bagit_directory(path)) {
			return path_list_add(list, path, (size_t)st.st_size);
		}
		return enumerate_directory(path, list);
	}
	/* Skip other types (symlinks, devices, etc.) */
	return 0;
}

static int enumerate_directory(const char* dir_path, path_list_t* list) {
	DIR* dir = opendir(dir_path);
	if (!dir) {
		/* Skip inaccessible directories (permission denied, etc.)
		 * rather than failing the entire enumeration. */
		int saved_errno = errno;
		fprintf(stderr, "\033[1;33mWARN\033[0m Skipping inaccessible directory: %s (%s)\n",
		        dir_path, strerror(saved_errno));
		return 0;
	}

	struct dirent* entry;
	while ((entry = readdir(dir)) != NULL) {
		/* Skip . and .. */
		if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
			continue;
		}

		/* Check max_files limit */
		if (list->max_files > 0 && list->count >= list->max_files) {
			break;
		}

		/* Build full path (handle trailing separator in dir_path) */
		size_t dir_len = strlen(dir_path);
		size_t name_len = strlen(entry->d_name);
		int needs_sep = (dir_len > 0 && !IS_PATH_SEP(dir_path[dir_len - 1])) ? 1 : 0;
		size_t path_len = dir_len + needs_sep + name_len;
		char* full_path = (char*)malloc(path_len + 1);
		if (!full_path) {
			closedir(dir);
			return -1;
		}

		memcpy(full_path, dir_path, dir_len);
		if (needs_sep) {
			full_path[dir_len] = PATH_SEP;
		}
		memcpy(full_path + dir_len + needs_sep, entry->d_name, name_len + 1);

		int rc = enumerate_path(full_path, list);
		free(full_path);

		if (rc != 0) {
			closedir(dir);
			return rc;
		}
	}

	closedir(dir);
	return 0;
}

/* Color support - these get set to empty strings if colors are disabled */
static const char* COLOR_GREEN = "\033[0;32m";
static const char* COLOR_RED = "\033[0;31m";
static const char* COLOR_YELLOW = "\033[1;33m";
static const char* COLOR_CYAN = "\033[0;36m";
static const char* COLOR_RESET = "\033[0m";
#define SLOW_THRESHOLD_NS (5LL * 1000000000LL)  /* 5 seconds in nanoseconds */

static int g_colors_enabled = 0;

/* JSON output mode: 0=off, 1=JSON array, 2=NDJSON (one JSON object per line) */
static int g_json_mode = 0;
static int g_json_first_result = 1; /* For comma-separation in JSON array mode */
static int g_wrote_hash_to_stderr_only = 0; /* Deferred stdout hash write */

static void init_colors(void) {
	/* Respect NO_COLOR environment variable (https://no-color.org/) */
	if (getenv("NO_COLOR") != NULL) {
		return;
	}

	/* Check if stdout is a terminal */
#ifdef _WIN32
	if (!isatty(_fileno(stdout))) {
		return;
	}
#else
	if (!isatty(STDOUT_FILENO)) {
		return;
	}
#endif

#ifdef _WIN32
	/* On Windows, try to enable ANSI escape sequences */
	HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
	if (hOut == INVALID_HANDLE_VALUE) {
		return;
	}

	DWORD dwMode = 0;
	if (!GetConsoleMode(hOut, &dwMode)) {
		return;
	}

	/* ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004 */
	dwMode |= 0x0004;
	if (!SetConsoleMode(hOut, dwMode)) {
		/* Failed to enable ANSI - older Windows or unsupported terminal */
		return;
	}
#endif

	/* Colors are supported */
	g_colors_enabled = 1;
}

static void disable_colors(void) {
	COLOR_GREEN = "";
	COLOR_RED = "";
	COLOR_YELLOW = "";
	COLOR_CYAN = "";
	COLOR_RESET = "";
}

static void enable_colors(void) {
	COLOR_GREEN = "\033[0;32m";
	COLOR_RED = "\033[0;31m";
	COLOR_YELLOW = "\033[1;33m";
	COLOR_CYAN = "\033[0;36m";
	COLOR_RESET = "\033[0m";
	g_colors_enabled = 1;
}

/* Initialize all output destinations from environment variables.
 * validate_getenv() checks all locale aliases (e.g., FAIL_OUT, FEHLER_AUS, ECHEC_SORTIE). */
static void init_output_destinations(void) {
	/* Table of output destinations: { pointer, env key, default stream, default muted }.
	 * A NULL default_stream with default_muted=1 means muted by default (e.g., debug/begin). */
	struct {
		output_dest_t* dest;
		uint8_t        env_id;
		FILE*          default_stream;
		int            default_muted;
	} output_table[] = {
		{ &g_ok_out,      VALIDATE_ENV_OK_OUT,      stdout, 0 },
		{ &g_warn_out,    VALIDATE_ENV_WARN_OUT,     stdout, 0 },
		{ &g_fail_out,    VALIDATE_ENV_FAIL_OUT,     stderr, 0 },
		{ &g_unknown_out, VALIDATE_ENV_UNKNOWN_OUT,  stdout, 0 },
		{ &g_slow_out,    VALIDATE_ENV_SLOW_OUT,     stdout, 0 },
		{ &g_debug_out,   VALIDATE_ENV_DEBUG_OUT,    NULL,   1 },
		{ &g_begin_out,   VALIDATE_ENV_BEGIN_OUT,    NULL,   1 },
	};

	for (size_t i = 0; i < sizeof(output_table) / sizeof(output_table[0]); i++) {
		output_dest_init(output_table[i].dest);
		const char* spec = validate_getenv(output_table[i].env_id);
		if (spec && spec[0] != '\0') {
			parse_output_spec(spec, output_table[i].dest);
		} else if (output_table[i].default_muted) {
			output_table[i].dest->muted = 1;
		} else {
			output_dest_add(output_table[i].dest, output_table[i].default_stream, 0);
		}
	}
}

static void shutdown_output_destinations(void) {
	output_dest_close(&g_ok_out);
	output_dest_close(&g_warn_out);
	output_dest_close(&g_fail_out);
	output_dest_close(&g_unknown_out);
	output_dest_close(&g_slow_out);
	output_dest_close(&g_debug_out);
	output_dest_close(&g_begin_out);
}

static size_t get_env_max_files(void) {
	const char* env = validate_getenv(VALIDATE_ENV_MAX_FILES);
	if (!env || env[0] == '\0') {
		return 0;
	}
	char* end = NULL;
	unsigned long long value = strtoull(env, &end, 10);
	if (end == env || value == 0) {
		return 0;
	}
	return (size_t)value;
}

/* ========== Validation Counts ========== */

typedef struct {
	size_t valid_count;
	size_t invalid_count;
	size_t unknown_count;
} validation_counts_t;

/* ========== Result Printing ========== */

/* Lock/unlock helpers for output synchronization (prevents TUI race conditions) */
static void output_lock(void) {
#if defined(_WIN32)
	if (!g_output_lock_initialized) {
		InitializeCriticalSection(&g_output_lock);
		g_output_lock_initialized = 1;
	}
	EnterCriticalSection(&g_output_lock);
#else
	pthread_mutex_lock(&g_output_lock);
#endif
}

static void output_unlock(void) {
#if defined(_WIN32)
	LeaveCriticalSection(&g_output_lock);
#else
	pthread_mutex_unlock(&g_output_lock);
#endif
}

/* Forward declarations — defined in TUI section below */
static int g_tui_enabled;
static int g_term_width;
static int g_term_height;
static void get_terminal_size(int* width, int* height);
#if !defined(_WIN32)
static volatile sig_atomic_t g_resize_signal;
#endif

/* Truncate a string to max_visible visible characters, skipping ANSI escape sequences.
 * Writes the truncated result into dst (must be at least dst_size bytes).
 * Handles UTF-8 by counting bytes per character. */
static void truncate_to_width(char* dst, size_t dst_size, const char* src, int max_visible) {
	size_t si = 0, di = 0;
	int visible = 0;
	size_t src_len = strlen(src);

	while (si < src_len && di < dst_size - 1) {
		if (src[si] == '\033' && si + 1 < src_len && src[si + 1] == '[') {
			/* ANSI CSI escape: copy everything through the terminator (letter) */
			while (si < src_len && di < dst_size - 1) {
				dst[di++] = src[si];
				if (src[si] >= 0x40 && src[si] <= 0x7E && src[si] != '[') {
					si++;
					break;
				}
				si++;
			}
		} else if (src[si] == '\n') {
			/* Preserve newlines */
			dst[di++] = src[si++];
		} else {
			/* Visible character — check if we've hit the limit */
			if (visible >= max_visible) {
				/* Stop copying visible content */
				break;
			}
			/* Copy UTF-8 character (1-4 bytes) */
			unsigned char c = (unsigned char)src[si];
			int char_bytes = 1;
			if (c >= 0xF0) char_bytes = 4;
			else if (c >= 0xE0) char_bytes = 3;
			else if (c >= 0xC0) char_bytes = 2;
			for (int b = 0; b < char_bytes && si < src_len && di < dst_size - 1; b++) {
				dst[di++] = src[si++];
			}
			visible++;
		}
	}
	dst[di] = '\0';
}

/* Write to an output destination, with colors only for stdout/stderr when colors enabled */
static void write_colored_line(output_dest_t* dest, const char* color_code,
							   const char* label, const char* rest) {
	if (dest->muted) return;  /* @null - no output */
	char line_buf[4096];
	char trunc_buf[4096];
	for (int i = 0; i < dest->count; i++) {
		FILE* f = dest->handles[i];
		if (!f) continue;

		/* Use colors only for stdout/stderr when colors are enabled */
		const char* rtl_prefix = (g_rtl_enabled && (f == stdout || f == stderr)) ? RLM : "";
		/* When TUI is active, append clear-to-EOL (\033[K) before newline to prevent
		 * progress bar remnants from trailing after shorter result lines */
		const char* eol_clear = (g_tui_enabled && (f == stdout || f == stderr)) ? "\033[K" : "";
		if (g_colors_enabled && (f == stdout || f == stderr)) {
			snprintf(line_buf, sizeof(line_buf), "%s%s%s%s%s%s\n",
					 rtl_prefix, color_code, label, COLOR_RESET, rest, eol_clear);
		} else {
			snprintf(line_buf, sizeof(line_buf), "%s%s%s%s\n", rtl_prefix, label, rest, eol_clear);
		}

		/* When TUI is active, truncate to terminal width to prevent wrapping */
		if (g_tui_enabled && g_term_width > 0 && (f == stdout || f == stderr)) {
			truncate_to_width(trunc_buf, sizeof(trunc_buf), line_buf, g_term_width);
			fputs(trunc_buf, f);
		} else {
			fputs(line_buf, f);
		}
		fflush(f);
	}
}

/* Write a detail line (indented sub-information) */
static void write_detail_line(output_dest_t* dest, const char* color_code, const char* text) {
	char line_buf[4096];
	for (int i = 0; i < dest->count; i++) {
		FILE* f = dest->handles[i];
		if (!f) continue;

		if (g_colors_enabled && (f == stdout || f == stderr)) {
			snprintf(line_buf, sizeof(line_buf), "  %s->%s %s\n", color_code, COLOR_RESET, text);
		} else {
			snprintf(line_buf, sizeof(line_buf), "  -> %s\n", text);
		}
		fputs(line_buf, f);
		fflush(f);
	}
}

/* Write debug output to DEBUG_OUT (muted by default unless DEBUG_OUT is set) */
static void debug_printf(const char* fmt, ...) {
	if (g_debug_out.muted) return;
	char line_buf[4096];
	va_list args;
	va_start(args, fmt);
	vsnprintf(line_buf, sizeof(line_buf), fmt, args);
	va_end(args);

	for (int i = 0; i < g_debug_out.count; i++) {
		FILE* f = g_debug_out.handles[i];
		if (!f) continue;
		fputs(line_buf, f);
		fflush(f);
	}
}

/* Escape a string for JSON output (handles \, ", control chars) */
static void json_escape(FILE* out, const char* s) {
	for (; *s; s++) {
		switch (*s) {
		case '"':  fputs("\\\"", out); break;
		case '\\': fputs("\\\\", out); break;
		case '\n': fputs("\\n", out); break;
		case '\r': fputs("\\r", out); break;
		case '\t': fputs("\\t", out); break;
		default:
			if ((unsigned char)*s < 0x20) {
				fprintf(out, "\\u%04x", (unsigned char)*s);
			} else {
				fputc(*s, out);
			}
		}
	}
}

/* Emit a single validation result as a JSON object to stdout */
static void emit_json_result(const char* path, const char* result) {
	char fmt_desc[256] = "";
	char fmt_id[64] = "";
	char fmt_cat[64] = "";
	char err_msg[1024] = "";
	char warn_msg[1024] = "";
	char depth_desc[128] = "";
	char err_code[64] = "";
	char depth_ceiling_reason[256] = "";

	kv_get_str(result, "fmt_desc", fmt_desc, sizeof(fmt_desc));
	kv_get_str(result, "fmt_id", fmt_id, sizeof(fmt_id));
	kv_get_str(result, "fmt_cat", fmt_cat, sizeof(fmt_cat));
	kv_get_str(result, "err", err_msg, sizeof(err_msg));
	kv_get_str(result, "warn", warn_msg, sizeof(warn_msg));
	kv_get_str(result, "depth_desc", depth_desc, sizeof(depth_desc));
	kv_get_str(result, "err_code", err_code, sizeof(err_code));
	kv_get_str(result, "depth_ceiling_reason", depth_ceiling_reason, sizeof(depth_ceiling_reason));

	int is_valid = kv_get_bool(result, "valid");
	int depth = (int)kv_get_u64(result, "depth_u8");
	uint64_t malform_bits = kv_get_u64(result, "malform_u64");
	int bypass_prot = kv_get_bool(result, "bypass_prot");
	int via_ffmpeg = kv_get_bool(result, "via_ffmpeg");

	if (g_json_mode == 1) {
		/* JSON array mode — comma-separate after first */
		if (!g_json_first_result) {
			fputs(",\n", stdout);
		}
		g_json_first_result = 0;
	}

	fputs("{", stdout);
	fputs("\"path\":\"", stdout); json_escape(stdout, path); fputs("\"", stdout);
	fputs(",\"valid\":", stdout); fputs(is_valid ? "true" : "false", stdout);
	fputs(",\"format\":\"", stdout); json_escape(stdout, fmt_id); fputs("\"", stdout);
	fputs(",\"format_description\":\"", stdout); json_escape(stdout, fmt_desc); fputs("\"", stdout);
	if (fmt_cat[0]) { fputs(",\"category\":\"", stdout); json_escape(stdout, fmt_cat); fputs("\"", stdout); }
	fputs(",\"depth\":", stdout); fprintf(stdout, "%d", depth);
	if (depth_desc[0]) { fputs(",\"depth_description\":\"", stdout); json_escape(stdout, depth_desc); fputs("\"", stdout); }
	if (depth_ceiling_reason[0]) { fputs(",\"depth_ceiling_reason\":\"", stdout); json_escape(stdout, depth_ceiling_reason); fputs("\"", stdout); }
	if (err_msg[0]) { fputs(",\"error\":\"", stdout); json_escape(stdout, err_msg); fputs("\"", stdout); }
	if (err_code[0]) { fputs(",\"error_code\":\"", stdout); json_escape(stdout, err_code); fputs("\"", stdout); }
	if (warn_msg[0]) { fputs(",\"warning\":\"", stdout); json_escape(stdout, warn_msg); fputs("\"", stdout); }
	if (malform_bits) { fprintf(stdout, ",\"malformations\":%llu", (unsigned long long)malform_bits); }
	if (bypass_prot) { fputs(",\"bypassed_protection\":true", stdout); }
	if (via_ffmpeg) { fputs(",\"via_ffmpeg\":true", stdout); }
	fputs("}", stdout);

	if (g_json_mode == 2) {
		/* NDJSON mode — newline after each object */
		fputs("\n", stdout);
	}
}

static void print_validation_result(const char* path, const char* result) {
	char fmt_desc[256];
	char err_msg[1024];
	char warn_msg[1024];

	kv_get_str(result, "fmt_desc", fmt_desc, sizeof(fmt_desc));
	kv_get_str(result, "err", err_msg, sizeof(err_msg));
	kv_get_str(result, "warn", warn_msg, sizeof(warn_msg));

	int is_valid = kv_get_bool(result, "valid");
	int depth = (int)kv_get_u64(result, "depth_u8");
	uint64_t malform_bits = kv_get_u64(result, "malform_u64");
	int bypass_prot = kv_get_bool(result, "bypass_prot");
	int via_ffmpeg = kv_get_bool(result, "via_ffmpeg");

	/* Get depth description from KV result (i18n-translated), fall back to numeric */
	char depth_str_buf[128];
	int got_depth_desc = kv_get_str(result, "depth_desc", depth_str_buf, sizeof(depth_str_buf));
	const char* depth_str = (got_depth_desc == 0 && depth_str_buf[0]) ? depth_str_buf
		: ((depth == 1) ? "fully validated" : "structural");

	/* Build depth description with optional ffmpeg suffix */
	char depth_desc[128];
	if (via_ffmpeg) {
		const char* ffmpeg_suffix = validate_tr(VALIDATE_STR_VIA_FFMPEG_SUFFIX);
		snprintf(depth_desc, sizeof(depth_desc), "%s, %s",
			depth_str, ffmpeg_suffix ? ffmpeg_suffix : "via ffmpeg");
	} else {
		snprintf(depth_desc, sizeof(depth_desc), "%s", depth_str);
	}

	int has_malformations = (malform_bits != 0);
	int has_warning = (warn_msg[0] != '\0');

	char rest_buf[2048];

	if (is_valid) {
		if (has_malformations || has_warning) {
			/* WARN goes to g_warn_out - all warnings on one line in brackets */
			char warn_details[1024] = "";
			int warn_pos = 0;
			int first_warn = 1;
			if (has_malformations) {
				for (int i = 0; i < VALIDATE_MALFORM_COUNT; i++) {
					if (malform_bits & (1ULL << i)) {
						const char* desc = validate_malform_desc(i);
						if (desc) {
							warn_pos += snprintf(warn_details + warn_pos, sizeof(warn_details) - warn_pos,
								"%s%s", first_warn ? "" : "; ", desc);
							first_warn = 0;
						}
					}
				}
			}
			if (has_warning) {
				warn_pos += snprintf(warn_details + warn_pos, sizeof(warn_details) - warn_pos,
					"%s%s", first_warn ? "" : "; ", warn_msg);
			}
			snprintf(rest_buf, sizeof(rest_buf), " %s: %s (%s) [%s]", path, fmt_desc, depth_desc, warn_details);
			write_colored_line(&g_warn_out, COLOR_YELLOW, validate_tr(VALIDATE_STR_LABEL_WARN), rest_buf);
		} else if (bypass_prot) {
			/* NOTICE is a special OK case, goes to g_ok_out */
			snprintf(rest_buf, sizeof(rest_buf), " %s: %s (%s) - trivial protection circumvented",
					 path, fmt_desc, depth_desc);
			write_colored_line(&g_ok_out, COLOR_YELLOW, validate_tr(VALIDATE_STR_LABEL_NOTICE), rest_buf);
		} else {
			/* OK goes to g_ok_out */
			snprintf(rest_buf, sizeof(rest_buf), " %s: %s (%s)", path, fmt_desc, depth_desc);
			write_colored_line(&g_ok_out, COLOR_GREEN, validate_tr(VALIDATE_STR_LABEL_OK), rest_buf);
		}
	} else {
		/* FAIL goes to g_fail_out - all details on one line */
		char fail_details[1024] = "";
		int fail_pos = 0;
		fail_pos += snprintf(fail_details, sizeof(fail_details), "%s",
			err_msg[0] ? err_msg : "Unknown error");
		if (has_malformations) {
			for (int i = 0; i < VALIDATE_MALFORM_COUNT; i++) {
				if (malform_bits & (1ULL << i)) {
					const char* desc = validate_malform_desc(i);
					if (desc) {
						fail_pos += snprintf(fail_details + fail_pos, sizeof(fail_details) - fail_pos,
							"; %s", desc);
					}
				}
			}
		}
		snprintf(rest_buf, sizeof(rest_buf), " %s: %s [%s]", path, fmt_desc, fail_details);
		write_colored_line(&g_fail_out, COLOR_RED, validate_tr(VALIDATE_STR_LABEL_FAIL), rest_buf);
	}
}

/* Global file list pointer for callback to access file sizes */
static path_list_t* g_file_list_ptr = NULL;

/* Progress state — backed by progrez library via validate_progress_* FFI */
/* g_tui_enabled forward-declared above write_colored_line */
static int g_term_width = 80;
static int g_term_height = 24;
static int g_simple_progress = 0;

/* Forward declarations for progress system */
static void progress_update_simple(size_t file_size);
static void progress_render_new(void);
static void progress_render_force(int force);

/* Begin callback - called when validation of a file starts */
static void on_validation_begin(
	void* context,
	uint32_t file_id,
	const char* path
) {
	(void)context;
	(void)file_id;
	if (g_begin_out.muted) return;

	/* Write BEGIN line to configured output(s) */
	for (int i = 0; i < g_begin_out.count; i++) {
		FILE* f = g_begin_out.handles[i];
		if (!f) continue;
		fprintf(f, "BEGIN %s\n", path);
		fflush(f);
	}
}

/* Batch validation callback */
static void on_validation_result(
	void* context,
	uint32_t file_id,
	const char* path,
	char* result
) {
	validation_counts_t* counts = (validation_counts_t*)context;

	/* Get elapsed time in nanoseconds */
	int64_t elapsed_ns = kv_get_i64(result, "elapsed_ns_u64");

	/* Look up file size for progress tracking (read-only on file list, no lock needed) */
	size_t file_size = 0;
	if (g_file_list_ptr) {
		for (size_t i = 0; i < g_file_list_ptr->count; i++) {
			if (g_file_list_ptr->ids[i] == file_id) {
				file_size = g_file_list_ptr->sizes[i];
				break;
			}
		}
	}

	/* Check if unknown */
	int is_unknown = kv_get_bool(result, "unknown");
	int is_valid = kv_get_bool(result, "valid");

	/* Lock for output + progress update + render to prevent race conditions.
	 * The progress update (counter increment + state mutation) MUST be inside
	 * the lock because progrez state has no internal synchronization. */
	output_lock();

	/* Update progress counters under lock (progrez state is not thread-safe) */
	if (g_tui_enabled) {
		progress_update_simple(file_size);

		/* Check for terminal resize — update width/height for result line truncation
		 * and scroll region adjustment. Progress rendering also checks this, but we
		 * need the updated width BEFORE printing result lines. */
#if !defined(_WIN32)
		if (g_resize_signal) {
			int new_w, new_h;
			get_terminal_size(&new_w, &new_h);
			if (new_h != g_term_height || new_w != g_term_width) {
				g_term_width = new_w;
				g_term_height = new_h;
				int scroll_bottom = new_h - 2;
				if (scroll_bottom < 1) scroll_bottom = 1;
				fprintf(stderr, "\033[1;%dr", scroll_bottom);
			}
			g_resize_signal = 0;
		}
#endif
	}

	/* Update counts */
	if (is_unknown) {
		if (counts) counts->unknown_count++;
	} else if (is_valid) {
		if (counts) counts->valid_count++;
	} else {
		if (counts) counts->invalid_count++;
	}

	/* Print result line(s) */
	if (g_json_mode) {
		emit_json_result(path, result);
	} else if (is_unknown) {
		char rest_buf[2048];
		snprintf(rest_buf, sizeof(rest_buf), " %s: Unknown", path);
		write_colored_line(&g_unknown_out, COLOR_CYAN, validate_tr(VALIDATE_STR_LABEL_UNKNOWN), rest_buf);
	} else {
		print_validation_result(path, result);
	}

	/* Print slow warning if applicable */
	if (elapsed_ns >= SLOW_THRESHOLD_NS) {
		double elapsed_s = (double)elapsed_ns / 1000000000.0;
		char rest_buf[2048];
		snprintf(rest_buf, sizeof(rest_buf), " %s: %.2fs", path, elapsed_s);
		write_colored_line(&g_slow_out, COLOR_YELLOW, validate_tr(VALIDATE_STR_LABEL_SLOW), rest_buf);
	}

	/* Now render progress bar AFTER output (in the fixed bottom area) */
	if (g_tui_enabled) {
		progress_render_new();
	}

	output_unlock();

	/* IMPORTANT: We take ownership of result, must free it */
	validate_free(result);
}

/* Forward declaration for path_list_swap (defined below in frontloading section) */
static void path_list_swap(path_list_t* list, size_t i, size_t j);

/* Shuffle array using Fisher-Yates algorithm */
static void shuffle_paths(path_list_t* list, uint64_t seed) {
	if (list->count <= 1) return;

	/* Simple LCG PRNG (good enough for shuffling) */
	uint64_t state = seed ? seed : (uint64_t)time(NULL);
	for (size_t i = list->count - 1; i > 0; i--) {
		state = state * 6364136223846793005ULL + 1442695040888963407ULL;
		size_t j = state % (i + 1);
		path_list_swap(list, i, j);
	}
}

/* ========== Frontloading Large Files ========== */
/*
 * Process top 10% largest files first to prevent apparent hangs at the end
 * when only large files remain. Uses quickselect to find P90 threshold.
 */

/* Swap elements at indices i and j */
static void path_list_swap(path_list_t* list, size_t i, size_t j) {
	if (i == j) return;
	char* tmp_path = list->paths[i];
	list->paths[i] = list->paths[j];
	list->paths[j] = tmp_path;
	uint32_t tmp_id = list->ids[i];
	list->ids[i] = list->ids[j];
	list->ids[j] = tmp_id;
	size_t tmp_size = list->sizes[i];
	list->sizes[i] = list->sizes[j];
	list->sizes[j] = tmp_size;
}

/* Quickselect partition - returns pivot index */
static size_t quickselect_partition(size_t* arr, size_t* indices, size_t left, size_t right) {
	size_t pivot = arr[right];
	size_t i = left;
	for (size_t j = left; j < right; j++) {
		if (arr[j] <= pivot) {
			size_t tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
			size_t tmp_idx = indices[i]; indices[i] = indices[j]; indices[j] = tmp_idx;
			i++;
		}
	}
	size_t tmp = arr[i]; arr[i] = arr[right]; arr[right] = tmp;
	size_t tmp_idx = indices[i]; indices[i] = indices[right]; indices[right] = tmp_idx;
	return i;
}

/* Quickselect to find the k-th smallest element */
static size_t quickselect(size_t* arr, size_t* indices, size_t left, size_t right, size_t k) {
	if (left == right) return arr[left];

	size_t pivot_index = quickselect_partition(arr, indices, left, right);
	if (k == pivot_index) {
		return arr[k];
	} else if (k < pivot_index) {
		return quickselect(arr, indices, left, pivot_index - 1, k);
	} else {
		return quickselect(arr, indices, pivot_index + 1, right, k);
	}
}

/* Find the file size at the given percentile (0-100) */
static size_t find_percentile_size(path_list_t* list, int percentile) {
	if (list->count == 0) return 0;

	/* Create a copy of sizes array for quickselect (it modifies the array) */
	size_t* sizes_copy = (size_t*)malloc(list->count * sizeof(size_t));
	size_t* indices = (size_t*)malloc(list->count * sizeof(size_t));
	if (!sizes_copy || !indices) {
		free(sizes_copy);
		free(indices);
		return 0;
	}

	for (size_t i = 0; i < list->count; i++) {
		sizes_copy[i] = list->sizes[i];
		indices[i] = i;
	}

	size_t k = (list->count * (size_t)percentile) / 100;
	if (k >= list->count) k = list->count - 1;

	size_t result = quickselect(sizes_copy, indices, 0, list->count - 1, k);

	free(sizes_copy);
	free(indices);
	return result;
}

/* Scatter large files evenly through queue for smoother memory/ETA (replaces frontloading) */
static void scatter_large_files(path_list_t* list) {
	if (list->count <= 10) return;

	size_t threshold = find_percentile_size(list, 90);
	if (threshold == 0) return;

	/* Separate large and small files */
	size_t* large_idx = (size_t*)malloc(list->count * sizeof(size_t));
	size_t* small_idx = (size_t*)malloc(list->count * sizeof(size_t));
	if (!large_idx || !small_idx) { free(large_idx); free(small_idx); return; }

	size_t large_count = 0, small_count = 0;
	for (size_t i = 0; i < list->count; i++) {
		if (list->sizes[i] >= threshold)
			large_idx[large_count++] = i;
		else
			small_idx[small_count++] = i;
	}

	if (large_count == 0) { free(large_idx); free(small_idx); return; }

	/* Build new order: interleave large files evenly among small files.
	 * If there are L large files and S small files, place one large file
	 * every (S / L) small files. This ensures at most ~1 large file is
	 * being processed per thread at any given time. */
	char** new_paths = (char**)malloc(list->count * sizeof(char*));
	uint32_t* new_ids = (uint32_t*)malloc(list->count * sizeof(uint32_t));
	size_t* new_sizes = (size_t*)malloc(list->count * sizeof(size_t));
	if (!new_paths || !new_ids || !new_sizes) {
		free(large_idx); free(small_idx);
		free(new_paths); free(new_ids); free(new_sizes);
		return;
	}

	/* Interleave: place a large file every `interval` positions */
	double interval = (small_count > 0 && large_count > 0)
		? (double)(small_count + large_count) / (double)large_count
		: 1.0;

	size_t dest = 0, si = 0, li = 0;
	double next_large = interval / 2.0; /* Start halfway through first interval — centered */

	for (size_t pos = 0; pos < list->count; pos++) {
		size_t src;
		if (li < large_count && (double)pos >= next_large) {
			src = large_idx[li++];
			next_large += interval;
		} else if (si < small_count) {
			src = small_idx[si++];
		} else if (li < large_count) {
			src = large_idx[li++];
		} else {
			break;
		}
		new_paths[dest] = list->paths[src];
		new_ids[dest] = list->ids[src];
		new_sizes[dest] = list->sizes[src];
		dest++;
	}

	if (validate_getenv(VALIDATE_ENV_VALIDATE_DEBUG)) {
		size_t large_bytes = 0, small_bytes = 0;
		for (size_t i = 0; i < large_count; i++) large_bytes += list->sizes[large_idx[i]];
		for (size_t i = 0; i < small_count; i++) small_bytes += list->sizes[small_idx[i]];
		fprintf(stderr, "[DEBUG] Scatter: %zu large files (%zu bytes) interleaved among %zu small files (%zu bytes), interval=%.1f\n",
				large_count, large_bytes, small_count, small_bytes, interval);
	}

	free(list->paths); free(list->ids); free(list->sizes);
	list->paths = new_paths;
	list->ids = new_ids;
	list->sizes = new_sizes;

	free(large_idx);
	free(small_idx);
}

/* ========== TUI Progress Bar ========== */
/*
 * Progress display backed by progrez library.
 * The progrez library handles all bar rendering, ETA, rate estimation, etc.
 * This code manages only the terminal scrolling region and cursor positioning.
 */

/* Cross-platform terminal size */
static void get_terminal_size(int* width, int* height) {
#if defined(_WIN32)
	CONSOLE_SCREEN_BUFFER_INFO csbi;
	HANDLE h = GetStdHandle(STD_ERROR_HANDLE);
	if (h != INVALID_HANDLE_VALUE && GetConsoleScreenBufferInfo(h, &csbi)) {
		*width = csbi.srWindow.Right - csbi.srWindow.Left + 1;
		*height = csbi.srWindow.Bottom - csbi.srWindow.Top + 1;
	} else {
		*width = 80;
		*height = 24;
	}
#else
	struct winsize ws;
	if (ioctl(STDERR_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0 && ws.ws_row > 0) {
		*width = ws.ws_col;
		*height = ws.ws_row;
	} else {
		/* Fallback to reasonable defaults */
		*width = 80;
		*height = 24;
	}
#endif
}

/* Signal handling for terminal resize (Unix only) */
#if !defined(_WIN32)
#ifndef SIGWINCH
#define SIGWINCH 28
#endif
static volatile sig_atomic_t g_resize_signal = 0;

static void sigwinch_handler(int sig) {
	(void)sig;
	g_resize_signal = 1;
}

/* Global flag to track SIGINT count - first is graceful, second is force */
static volatile sig_atomic_t g_sigint_count = 0;

/* SIGINT handler - graceful on first, force exit on second */
static void sigint_handler(int sig) {
	(void)sig;
	g_sigint_count++;

	if (g_sigint_count == 1) {
		/* First Ctrl+C: signal graceful shutdown */
		validate_interrupt();

		/* Write message directly (async-signal-safe using write()) */
		const char* msg = "\n\033[33mInterrupted - finishing current files (Ctrl+C again to force quit)...\033[0m\n";
		(void)write(STDERR_FILENO, msg, strlen(msg));
	} else {
		/* Second Ctrl+C: force exit immediately */
		/* Clean up terminal state before exiting */
		const char* cleanup = "\033[r\033[?25h\033[999;1H\n";
		(void)write(STDERR_FILENO, cleanup, strlen(cleanup));

		const char* msg = "\033[31mForce quit.\033[0m\n";
		(void)write(STDERR_FILENO, msg, strlen(msg));

		_exit(130);  /* 128 + SIGINT(2) = standard interrupted exit code */
	}
}
#endif

/* Initialize progress state (backed by progrez library) */
static void progress_init_new(size_t total_files, size_t total_bytes, int simple) {
	validate_progress_init("validate");

	int w, h;
	get_terminal_size(&w, &h);
	int is_tty = isatty(STDERR_FILENO);

	/* Enable TUI if:
	 * - stderr is a TTY (not piped/redirected)
	 * - More than 1 file to validate
	 * - Terminal height is at least 5 lines (need room for scrolling region + status)
	 */
	g_tui_enabled = is_tty && total_files > 1 && h >= 5;
	g_simple_progress = simple;

	validate_progress_detect_caps(is_tty, simple, (uint16_t)w);
	validate_progress_set_determinate((uint64_t)total_files, (uint64_t)total_bytes);
	g_term_width = w;
	g_term_height = h;

	/* Debug output for TUI enablement */
	if (validate_getenv(VALIDATE_ENV_VALIDATE_DEBUG)) {
		fprintf(stderr, "[TUI] is_tty=%d, files=%zu, simple=%d, height=%d -> enabled=%d\n",
				is_tty, total_files, simple, h, g_tui_enabled);
		fprintf(stderr, "[TUI] total_bytes=%zu\n", total_bytes);
	}

#if !defined(_WIN32)
	if (g_tui_enabled) {
		struct sigaction sa;

		/* SIGWINCH for terminal resize */
		sa.sa_handler = sigwinch_handler;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = SA_RESTART;
		sigaction(SIGWINCH, &sa, NULL);

		/* SIGINT for clean Ctrl+C exit (restore terminal before dying) */
		sa.sa_handler = sigint_handler;
		sigemptyset(&sa.sa_mask);
		sa.sa_flags = 0;
		sigaction(SIGINT, &sa, NULL);

		/* Set up scrolling region: reserve bottom 2 lines for progress */
		int scroll_bottom = h - 2;
		if (scroll_bottom < 1) scroll_bottom = 1;
		fprintf(stderr, "\033[1;%dr", scroll_bottom);
		fflush(stderr);
	}
#else
	/* Windows: TUI with scrolling regions requires Console API */
	g_tui_enabled = 0;
#endif
}

static void progress_cleanup_new(void) {
	if (!g_tui_enabled) return;

	/* Clear progress bar lines BEFORE resetting scrolling region */
	fprintf(stderr, "\033[%d;1H\033[K", g_term_height - 1);  /* Clear HR line */
	fprintf(stderr, "\033[%d;1H\033[K", g_term_height);       /* Clear progress line */

	/* Reset scrolling region to full terminal */
	fprintf(stderr, "\033[r");

	/* Re-enable line wrap */
	fprintf(stderr, "\033[?7h");

	/* Move cursor to bottom */
	fprintf(stderr, "\033[999;1H");

	/* Scroll for Summary output */
	fflush(stderr);
	printf("\n");
	fflush(stdout);

	/* Disable TUI flag so atexit handler won't double-reset */
	g_tui_enabled = 0;
}

/* atexit handler to restore terminal on abnormal exit (e.g., Ctrl+C) */
static void restore_terminal_on_exit(void) {
	if (g_tui_enabled) {
		fprintf(stderr, "\033[r\033[?7h");
		fflush(stderr);
	}
}

/* Update progress after completing a file */
static void progress_update_simple(size_t file_size) {
	validate_progress_update((uint64_t)file_size);
}

/* Draw horizontal rule on the second-to-last terminal line */
static void draw_hr(int width, int simple) {
	if (simple) {
		for (int i = 0; i < width; i++) {
			fprintf(stderr, "-");
		}
	} else {
		fprintf(stderr, "\033[38;5;240m");  /* Dark gray */
		for (int i = 0; i < width; i++) {
			fprintf(stderr, "\xe2\x94\x80");  /* ─ U+2500 */
		}
		fprintf(stderr, "\033[0m");
	}
}

/* Get monotonic time in milliseconds */
static uint64_t get_monotonic_ms(void) {
#if defined(_WIN32)
	return GetTickCount64();
#else
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
#endif
}

static uint64_t g_last_render_ms = 0;
#define RENDER_INTERVAL_MS 33  /* ~30fps cap to prevent flicker */

/* Render progress display (backed by progrez library).
 * Rate-limited to RENDER_INTERVAL_MS to avoid flicker from rapid callbacks.
 * Pass force=1 to bypass rate-limiting (e.g., initial render, final render). */
static void progress_render_force(int force) {
	if (!g_tui_enabled) return;

	/* Rate-limit: skip if rendered recently (unless forced) */
	uint64_t now_ms = get_monotonic_ms();
	if (!force && (now_ms - g_last_render_ms) < RENDER_INTERVAL_MS) return;
	g_last_render_ms = now_ms;

	/* Poll terminal size for responsive resize handling */
	int new_width, new_height;
	get_terminal_size(&new_width, &new_height);

	if (new_height != g_term_height) {
		/* Height changed — re-setup scrolling region */
		int scroll_bottom = new_height - 2;
		if (scroll_bottom < 1) scroll_bottom = 1;
		fprintf(stderr, "\033[1;%dr", scroll_bottom);
	}

	g_term_width = new_width;
	g_term_height = new_height;

#if !defined(_WIN32)
	g_resize_signal = 0;
#endif

	if (new_width < 40) return;  /* Too narrow */

	/* Disable line wrap + save cursor (prevents wrapping artifacts in fixed area) */
	fprintf(stderr, "\033[?7l\033[s");

	/* Draw horizontal rule on line height-1 */
	fprintf(stderr, "\033[%d;1H\033[K", g_term_height - 1);
	draw_hr(g_term_width, g_simple_progress);

	/* Draw progress bar on last line (rendered by progrez) */
	fprintf(stderr, "\033[%d;1H\033[K", g_term_height);

	char buf[4096];
	size_t len = validate_progress_render_line(buf, sizeof(buf), (uint16_t)g_term_width);
	if (len > 0) {
		fwrite(buf, 1, len, stderr);
	}

	/* Restore cursor + re-enable line wrap */
	fprintf(stderr, "\033[u\033[?7h");
	fflush(stderr);
}

/* Render progress display (rate-limited) */
static void progress_render_new(void) {
	progress_render_force(0);
}

static void print_usage(const char* program) {
	printf("validate - Deterministic file format validation\n\n");
	printf("USAGE:\n");
	printf("    %s [options] <path> [path ...]\n", program);
	printf("    find . -name '*.jpg' | %s --json\n", program);
	printf("    %s --json - < paths.txt\n", program);
	printf("\n");
	printf("INPUT:\n");
	printf("    Paths can be files or directories (recursed automatically).\n");
	printf("    Use -, --stdin, or @stdin to read paths from stdin (newline-delimited).\n");
	printf("    If no paths given and stdin is piped, paths are read automatically.\n");
	printf("\n");
	printf("OPTIONS:\n");
#ifdef _WIN32
	printf("    /version, --version     Print version\n");
	printf("    /?, /h, /help, --help   Show this help\n");
	printf("    /j N, /jobs N           Number of parallel workers (0 = auto)\n");
	printf("    --no-color              Disable colored output\n");
	printf("    --color                 Force colored output (even when piping)\n");
	printf("    --shuffle               Shuffle file order (helps expose race conditions)\n");
	printf("    --stress N              Repeat validation N times with shuffling\n");
	printf("    --no-frontload          Don't reorder files by size (default: large files scattered evenly)\n");
	printf("    --simple-progress       Use simple ASCII progress instead of TUI status bar\n");
	printf("    --append                Append to output files instead of overwriting\n");
	printf("    --json                  Output results as a JSON array\n");
	printf("    --ndjson                Output results as newline-delimited JSON (one object per line)\n");
	printf("    --about                 Print version and platform info\n");
	printf("    --lang CODE             Set output language (e.g., en, de)\n");
#else
	printf("    --version          Print version\n");
	printf("    --help             Show this help\n");
	printf("    --jobs N           Number of parallel workers (0 = auto)\n");
	printf("    -j N               Alias for --jobs\n");
	printf("    --no-color         Disable colored output\n");
	printf("    --color            Force colored output (even when piping)\n");
	printf("    --shuffle          Shuffle file order (helps expose race conditions)\n");
	printf("    --stress N         Repeat validation N times with shuffling\n");
	printf("    --no-frontload     Don't reorder files by size (default: large files scattered evenly)\n");
	printf("    --simple-progress  Use simple ASCII progress instead of TUI status bar\n");
	printf("    --append           Append to output files instead of overwriting\n");
	printf("    --json             Output results as a JSON array\n");
	printf("    --ndjson           Output results as newline-delimited JSON (one object per line)\n");
	printf("    --about            Print version and platform info\n");
	printf("    --max-memory SIZE  Memory budget (e.g., 4G, 2048M). Default: half of system RAM\n");
	printf("    --lang CODE        Set output language (e.g., en, de)\n");
	printf("    --test-coverage N  Run N corruption rounds against a file, report detection rate\n");
	printf("    --modes LIST       Corruption modes for --test-coverage (comma-sep; default = all 6)\n");
	printf("                       Valid: sniper, shotgun, header, tail, zeroed, xor, sparse-noise, boundary\n");
	printf("    --shotgun-bytes N  Bytes overwritten by shotgun/header/tail/zeroed/xor (default 4096; accepts K/M suffix)\n");
#endif
	printf("\n");
	printf("ENVIRONMENT:\n");
	printf("    NO_COLOR      Disable colored output\n");
	printf("    OK_OUT        Output destinations for OK results (default: stdout)\n");
	printf("    WARN_OUT      Output destinations for WARN results (default: stdout)\n");
	printf("    FAIL_OUT      Output destinations for FAIL results (default: stderr)\n");
	printf("    UNKNOWN_OUT   Output destinations for UNKNOWN results (default: stdout)\n");
	printf("    SLOW_OUT      Output destinations for SLOW results (default: stdout)\n");
	printf("    DEBUG_OUT     Output destinations for debug messages (default: @null)\n");
	printf("    BEGIN_OUT     Output when files start validation (default: @null)\n");
	printf("                  Useful for debugging crashes - shows 'in-flight' files\n");
	printf("    MAX_FILES     Limit number of files to validate\n");
	printf("    LANG          Locale for output language (e.g., de_DE.UTF-8)\n");
	printf("    LC_MESSAGES   Locale for output language (overrides LANG)\n");
	printf("    NO_BIDI       Disable bidirectional text marks for RTL languages\n");
	printf("    MAX_MEMORY    Memory budget (e.g., 4G, 2048M). Same as --max-memory\n");
	printf("\n");
	printf("OUTPUT REDIRECTION:\n");
	printf("    All *_OUT variables accept colon-separated destinations.\n");
	printf("    Special tokens: @stdout, @stderr, @null (mute output)\n");
	printf("    Example: FAIL_OUT=/tmp/fails.log:@stderr (logs to file AND stderr)\n");
	printf("    Example: OK_OUT=@null (suppress OK results entirely)\n");
	printf("    Note: @null must appear alone; combining it with other destinations is an error.\n");
	printf("    Note: Windows paths like C:\\path are handled correctly.\n");
	printf("\n");
	printf("OUTPUT TYPES:\n");
	printf("    OK      Valid file (stdout by default)\n");
	printf("    WARN    Valid file with non-fatal issues (stdout by default)\n");
	printf("    FAIL    Invalid file (stderr by default)\n");
	printf("    UNKNOWN Unrecognized format (stdout by default)\n");
	printf("\n");
	printf("By default, the top 10%% largest files are processed first to prevent\n");
	printf("apparent hangs at the end when only large files remain.\n");
	printf("smoother memory usage and more accurate ETA. Use --no-frontload to disable.\n");
	printf("\n%s\n", validate_tr(VALIDATE_STR_HELP_ENTROPY_SHIELD));
	printf("Support: support@entropyshield.app\n");
}

/**
 * Parse a CLI argument string into a validate_arg_t.
 * Handles --long, -short, and /windows prefix forms.
 * Short forms (-h, -j) and Windows forms (/?, /h, /help, /j, /jobs, /version)
 * are hardcoded here. Long forms (--anything) are resolved through the
 * i18n alias system via validate_match_arg().
 */
static uint8_t parse_cli_arg(const char* arg) {
	/* Short forms (hardcoded, not localized) */
	if (strcmp(arg, "-h") == 0) return VALIDATE_ARG_HELP;
	if (strcmp(arg, "-j") == 0) return VALIDATE_ARG_JOBS;

#ifdef _WIN32
	/* Windows prefix forms */
	if (strcmp(arg, "/?") == 0) return VALIDATE_ARG_HELP;
	if (arg[0] == '/') {
		/* Strip / prefix and look up via alias system */
		uint8_t result = validate_match_arg(arg + 1);
		if (result != VALIDATE_ARG_UNKNOWN) return result;
		return VALIDATE_ARG_UNKNOWN;
	}
#endif

	/* -- prefix: strip and look up via alias system */
	if (arg[0] == '-' && arg[1] == '-') {
		return validate_match_arg(arg + 2);
	}

	return VALIDATE_ARG_UNKNOWN;
}

int main(int argc, char* argv[]) {
	/* Compute SHA-256 of the running binary for provenance tracking */
	compute_self_hash(argv[0]);
	/* Verify binary integrity (if build appended integrity trailer) */
	verify_self_integrity(argv[0]);
	/* Write hash to stdout and stderr — but only once if they go to the same place.
	 * Compare via fstat: if both are the same device+inode (same file/TTY), write once to stderr.
	 * If either fstat fails (pipe, etc.), compare isatty: both TTYs means same terminal. */
	{
		int same_dest = 0;
#if defined(_WIN32)
		/* Windows: compare console handles via GetFileInformationByHandle */
		HANDLE h_out = GetStdHandle(STD_OUTPUT_HANDLE);
		HANDLE h_err = GetStdHandle(STD_ERROR_HANDLE);
		if (h_out != INVALID_HANDLE_VALUE && h_err != INVALID_HANDLE_VALUE) {
			BY_HANDLE_FILE_INFORMATION info_out, info_err;
			if (GetFileInformationByHandle(h_out, &info_out) &&
				GetFileInformationByHandle(h_err, &info_err)) {
				if (info_out.dwVolumeSerialNumber == info_err.dwVolumeSerialNumber &&
					info_out.nFileIndexHigh == info_err.nFileIndexHigh &&
					info_out.nFileIndexLow == info_err.nFileIndexLow) {
					same_dest = 1;
				}
			} else {
				/* GetFileInformationByHandle fails for console handles;
				 * if both are consoles, they're the same terminal */
				DWORD mode_out, mode_err;
				if (GetConsoleMode(h_out, &mode_out) && GetConsoleMode(h_err, &mode_err)) {
					same_dest = 1;
				}
			}
		}
#else
		/* POSIX: compare via fstat dev+ino, fall back to isatty */
		struct stat st_out, st_err;
		int have_out = (fstat(STDOUT_FILENO, &st_out) == 0);
		int have_err = (fstat(STDERR_FILENO, &st_err) == 0);
		if (have_out && have_err && st_out.st_dev == st_err.st_dev && st_out.st_ino == st_err.st_ino) {
			same_dest = 1;
		} else if (isatty(STDOUT_FILENO) && isatty(STDERR_FILENO)) {
			same_dest = 1;
		}
#endif
		if (same_dest) {
			write_self_hash(stderr);
		} else {
			/* Defer stdout hash — might be suppressed in JSON mode.
			 * Always write to stderr immediately. */
			write_self_hash(stderr);
			g_wrote_hash_to_stderr_only = 1;
		}
	}

	/* Initialize color support based on terminal capabilities */
	init_colors();
	if (!g_colors_enabled) {
		disable_colors();
	}

	if (argc < 2 && isatty(STDIN_FILENO)) {
		print_usage(argv[0]);
		return 2;
	}

	size_t jobs = 0;
	int test_coverage_mode = 0;
	uint32_t test_coverage_rounds = 100;
	uint32_t test_coverage_modes_bitmask = 0; /* 0 = all default modes */
	uint32_t test_coverage_shotgun_bytes = 4096;
	int shuffle = 0;
	size_t stress_iterations = 0;
	int no_frontload = 0;
	int simple_progress = 0;

	/* Auto-detect locale from environment (--lang overrides this) */
	validate_set_locale(NULL);
	g_rtl_enabled = validate_is_rtl() && !validate_getenv(VALIDATE_ENV_NO_BIDI);

	/* Collect positional arguments (paths) */
	const char** paths = NULL;
	size_t path_count = 0;
	size_t path_capacity = 0;

	for (int i = 1; i < argc; i++) {
		const char* arg = argv[i];

		/* Check if this looks like an option (starts with - or / on Windows) */
		int is_option = (arg[0] == '-' && arg[1] != '\0'); /* "-" alone is stdin, not an option */
#ifdef _WIN32
		if (arg[0] == '/' && arg[1] != '\0' && arg[1] != '/' && arg[1] != '\\')
			is_option = 1;
#endif

		if (is_option) {
			uint8_t arg_id = parse_cli_arg(arg);
			switch (arg_id) {
			case VALIDATE_ARG_HELP:
				print_usage(argv[0]);
				free(paths);
				return 0;
			case VALIDATE_ARG_VERSION:
				printf("%s\n", validate_version());
				free(paths);
				return 0;
			case VALIDATE_ARG_SHUFFLE:
				shuffle = 1;
				continue;
			case VALIDATE_ARG_STRESS:
				if (i + 1 >= argc) {
					fprintf(stderr, "%sError: --stress requires a value\n%s", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				stress_iterations = (size_t)strtoull(argv[++i], NULL, 10);
				if (stress_iterations == 0) {
					fprintf(stderr, "%sError: --stress value must be > 0\n%s", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				continue;
			case VALIDATE_ARG_JOBS:
				if (i + 1 >= argc) {
					fprintf(stderr, "%sError: --jobs requires a value\n%s", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				jobs = (size_t)strtoull(argv[++i], NULL, 10);
				continue;
			case VALIDATE_ARG_LANG:
				if (i + 1 >= argc) {
					fprintf(stderr, "%sError: --lang requires a value\n%s", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				validate_set_locale(argv[++i]);
				g_rtl_enabled = validate_is_rtl() && !validate_getenv(VALIDATE_ENV_NO_BIDI);
				continue;
			case VALIDATE_ARG_NO_COLOR:
				disable_colors();
				continue;
			case VALIDATE_ARG_COLOR:
				enable_colors();  /* Force colors on even if not TTY */
				continue;
			case VALIDATE_ARG_NO_FRONTLOAD:
				no_frontload = 1;
				continue;
			case VALIDATE_ARG_SIMPLE_PROGRESS:
				simple_progress = 1;
				continue;
			case VALIDATE_ARG_APPEND:
				g_file_open_mode = "a";
				continue;
			case VALIDATE_ARG_JSON:
				g_json_mode = 1;
				disable_colors();
				continue;
			case VALIDATE_ARG_NDJSON:
				g_json_mode = 2;
				disable_colors();
				continue;
			case VALIDATE_ARG_ABOUT:
				printf("validate %s %s-%s\n", validate_version(),
#if defined(__aarch64__) || defined(_M_ARM64)
					"aarch64",
#elif defined(__x86_64__) || defined(_M_X64)
					"x86_64",
#else
					"unknown",
#endif
#if defined(__APPLE__)
					"darwin"
#elif defined(_WIN32)
					"windows"
#elif defined(__linux__)
					"linux"
#else
					"unknown"
#endif
				);
				free(paths);
				return 0;
			case VALIDATE_ARG_MAX_MEMORY: {
				if (i + 1 >= argc) {
					fprintf(stderr, "%sError: --max-memory requires a value (e.g., 4G, 2048M, 1073741824)%s\n", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				const char *val = argv[++i];
				char *endptr;
				uint64_t mem = strtoull(val, &endptr, 10);
				if (*endptr == 'G' || *endptr == 'g') mem *= 1024ULL * 1024 * 1024;
				else if (*endptr == 'M' || *endptr == 'm') mem *= 1024ULL * 1024;
				else if (*endptr == 'K' || *endptr == 'k') mem *= 1024ULL;
				validate_set_max_memory(mem);
				continue;
			}
			case VALIDATE_ARG_TEST_COVERAGE: {
				test_coverage_mode = 1;
				/* Optional numeric argument specifies rounds */
				if (i + 1 < argc && argv[i + 1][0] >= '0' && argv[i + 1][0] <= '9') {
					char *endptr;
					unsigned long n = strtoul(argv[++i], &endptr, 10);
					if (*endptr == '\0' && n > 0 && n <= 100000) {
						test_coverage_rounds = (uint32_t)n;
					}
				}
				continue;
			}
			case VALIDATE_ARG_MODES: {
				/* --modes sniper,shotgun,header,tail,zeroed,xor,sparse-noise,boundary
				 * (comma-separated; case-insensitive; hyphen or underscore accepted) */
				if (++i >= argc) {
					fprintf(stderr, "%sError: --modes requires a comma-separated list%s\n", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				const char *list = argv[i];
				uint32_t bitmask = 0;
				const char *start = list;
				for (;;) {
					const char *end = start;
					while (*end && *end != ',') end++;
					size_t len = (size_t)(end - start);
					/* Compare case-insensitively, accepting '_' and '-' interchangeably */
					char buf[32] = {0};
					if (len == 0 || len >= sizeof(buf)) {
						fprintf(stderr, "%sError: invalid --modes token (empty or too long)%s\n", COLOR_RED, COLOR_RESET);
						free(paths);
						return 2;
					}
					for (size_t k = 0; k < len; k++) {
						char c = start[k];
						if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
						if (c == '_') c = '-';
						buf[k] = c;
					}
					uint32_t bit = 0;
					if (strcmp(buf, "sniper") == 0) bit = 1u << 0;
					else if (strcmp(buf, "shotgun") == 0) bit = 1u << 1;
					else if (strcmp(buf, "header") == 0) bit = 1u << 2;
					else if (strcmp(buf, "tail") == 0) bit = 1u << 3;
					else if (strcmp(buf, "zeroed") == 0) bit = 1u << 4;
					else if (strcmp(buf, "xor") == 0) bit = 1u << 5;
					else if (strcmp(buf, "sparse-noise") == 0) bit = 1u << 6;
					else if (strcmp(buf, "boundary") == 0) bit = 1u << 7;
					else {
						fprintf(stderr, "%sError: unknown mode '%s'. Valid: sniper, shotgun, header, tail, zeroed, xor, sparse-noise, boundary%s\n",
							COLOR_RED, buf, COLOR_RESET);
						free(paths);
						return 2;
					}
					bitmask |= bit;
					if (*end == '\0') break;
					start = end + 1;
				}
				test_coverage_modes_bitmask = bitmask;
				continue;
			}
			case VALIDATE_ARG_SHOTGUN_BYTES: {
				if (++i >= argc) {
					fprintf(stderr, "%sError: --shotgun-bytes requires a numeric argument%s\n", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				char *endptr;
				unsigned long n = strtoul(argv[i], &endptr, 10);
				/* Accept K/M suffix like --max-memory */
				if (*endptr == 'K' || *endptr == 'k') n *= 1024;
				else if (*endptr == 'M' || *endptr == 'm') n *= 1024UL * 1024;
				else if (*endptr != '\0') {
					fprintf(stderr, "%sError: invalid --shotgun-bytes value '%s'%s\n", COLOR_RED, argv[i], COLOR_RESET);
					free(paths);
					return 2;
				}
				if (n == 0 || n > 1024UL * 1024) {
					fprintf(stderr, "%sError: --shotgun-bytes must be 1..1M%s\n", COLOR_RED, COLOR_RESET);
					free(paths);
					return 2;
				}
				test_coverage_shotgun_bytes = (uint32_t)n;
				continue;
			}
			default:
				fprintf(stderr, "%sError: Unknown option: %s\n%s", COLOR_RED, arg, COLOR_RESET);
				free(paths);
				return 2;
			}
		}
		/* Add positional argument to paths list */
		if (path_count >= path_capacity) {
			size_t new_capacity = path_capacity == 0 ? 8 : path_capacity * 2;
			const char** new_paths = realloc(paths, new_capacity * sizeof(const char*));
			if (!new_paths) {
				fprintf(stderr, "%sError: Out of memory\n%s", COLOR_RED, COLOR_RESET);
				free(paths);
				return 1;
			}
			paths = new_paths;
			path_capacity = new_capacity;
		}
		paths[path_count++] = arg;
	}

	/* Remove "-", "--stdin", or "@stdin" from paths (stdin sentinel markers).
	 * Their presence (or no args + piped stdin) triggers reading paths from stdin. */
	for (size_t i = 0; i < path_count; ) {
		if (strcmp(paths[i], "-") == 0 || strcmp(paths[i], "--stdin") == 0 || strcmp(paths[i], "@stdin") == 0) {
			for (size_t j = i; j + 1 < path_count; j++) paths[j] = paths[j+1];
			path_count--;
		} else {
			i++;
		}
	}

	/* If no paths remain and stdin is piped, read newline-delimited paths from stdin */
	if (path_count == 0 && !isatty(STDIN_FILENO)) {
		char line[4096];
		while (fgets(line, sizeof(line), stdin)) {
			size_t len = strlen(line);
			while (len > 0 && (line[len-1] == '\n' || line[len-1] == '\r')) line[--len] = '\0';
			if (len == 0) continue;

			if (path_count >= path_capacity) {
				size_t new_capacity = path_capacity == 0 ? 64 : path_capacity * 2;
				const char** new_paths = realloc(paths, new_capacity * sizeof(const char*));
				if (!new_paths) break;
				paths = new_paths;
				path_capacity = new_capacity;
			}
			paths[path_count++] = strdup(line);
		}
	}

	if (path_count == 0) {
		print_usage(argv[0]);
		free(paths);
		return 2;
	}

	/* Pre-initialize decoder libraries for thread safety.
	 * This must be called ONCE from main thread BEFORE spawning workers. */
	validate_init();

	/* Test-coverage mode: run corruption detection on each path */
	if (test_coverage_mode) {
		if (path_count == 0) {
			fprintf(stderr, "%sError: --test-coverage requires a file path%s\n", COLOR_RED, COLOR_RESET);
			free(paths);
			return 2;
		}
		int overall_exit = 0;
		const char *modes[] = { "sniper", "shotgun", "header", "tail", "zeroed", "xor" };
		for (size_t i = 0; i < path_count; i++) {
			uint64_t seed = (uint64_t)time(NULL);
			const char *seed_env = getenv("VALIDATE_SEED");
			if (seed_env && *seed_env) {
				char *endp;
				unsigned long long v = strtoull(seed_env, &endp, 0);
				if (*endp == '\0') seed = (uint64_t)v;
			}
			fprintf(stderr, "%sTest coverage: %s (rounds=%u, seed=%llu, modes=0x%x, shotgun=%u)...%s\n", COLOR_CYAN, paths[i], test_coverage_rounds, (unsigned long long)seed, test_coverage_modes_bitmask, test_coverage_shotgun_bytes, COLOR_RESET);
			char *result = validate_test_coverage(paths[i], test_coverage_rounds, seed, test_coverage_shotgun_bytes, test_coverage_modes_bitmask, NULL, NULL);
			if (!result) {
				fprintf(stderr, "%sFAILED%s: could not run coverage on %s (baseline validation failed?)\n", COLOR_RED, COLOR_RESET, paths[i]);
				overall_exit = 1;
				continue;
			}
			/* Parse and pretty-print */
			char fmt_buf[64] = {0};
			kv_get_str(result, "fmt", fmt_buf, sizeof(fmt_buf));
			uint64_t file_size = kv_get_u64(result, "file_size");
			uint64_t rounds = kv_get_u64(result, "rounds");
			uint64_t detected = kv_get_u64(result, "detected");
			uint64_t duration_ns = kv_get_u64(result, "duration_ns");
			double duration_s = (double)duration_ns / 1e9;

			printf("\n%s%s%s  (%llu bytes)\n", COLOR_CYAN, paths[i], COLOR_RESET,
				(unsigned long long)file_size);
			printf("  Format: %s%s%s\n", COLOR_CYAN, fmt_buf, COLOR_RESET);
			double overall_pct = rounds > 0 ? 100.0 * (double)detected / (double)rounds : 0.0;
			const char *overall_color = overall_pct >= 95.0 ? COLOR_GREEN : (overall_pct >= 70.0 ? COLOR_YELLOW : COLOR_RED);
			printf("  Overall: %s%llu/%llu (%.1f%%)%s  in %.2fs\n\n",
				overall_color, (unsigned long long)detected, (unsigned long long)rounds, overall_pct, COLOR_RESET, duration_s);

			printf("  %-10s %8s %8s %8s  %-14s\n", "Mode", "Detected", "Total", "Rate", "95% CI");
			printf("  %-10s %8s %8s %8s  %-14s\n", "----", "--------", "-----", "----", "------");
			for (size_t m = 0; m < 6; m++) {
				char key_total[32], key_det[32];
				snprintf(key_total, sizeof(key_total), "mode_%s_total", modes[m]);
				snprintf(key_det, sizeof(key_det), "mode_%s_detected", modes[m]);
				uint64_t mt = kv_get_u64(result, key_total);
				uint64_t md = kv_get_u64(result, key_det);
				if (mt == 0) continue;
				double pct = 100.0 * (double)md / (double)mt;
				const char *color = pct >= 95.0 ? COLOR_GREEN : (pct >= 70.0 ? COLOR_YELLOW : COLOR_RED);
				/* 95% Wilson score interval — well-behaved at small n and at p near 0/1
				 * where the naive normal-approximation interval collapses. */
				const double z = 1.959963984540054; /* 97.5th percentile of N(0,1) */
				double n = (double)mt;
				double p = (double)md / n;
				double z2 = z * z;
				double denom = 1.0 + z2 / n;
				double center = (p + z2 / (2.0 * n)) / denom;
				double radius = (z * sqrt((p * (1.0 - p) + z2 / (4.0 * n)) / n)) / denom;
				double ci_low = (center - radius) * 100.0;
				double ci_high = (center + radius) * 100.0;
				if (ci_low < 0.0) ci_low = 0.0;
				if (ci_high > 100.0) ci_high = 100.0;
				char ci_buf[24];
				snprintf(ci_buf, sizeof(ci_buf), "[%4.1f, %5.1f]", ci_low, ci_high);
				printf("  %-10s %8llu %8llu %s%7.1f%%%s  %-14s\n", modes[m],
					(unsigned long long)md, (unsigned long long)mt, color, pct, COLOR_RESET, ci_buf);
			}

			char heat_buf[4096] = {0};
			if (kv_get_str(result, "heatmap", heat_buf, sizeof(heat_buf)) == 0 && heat_buf[0] != '\0') {
				printf("\n  Undetected-corruption heatmap (darker = colder, brighter = hotter):\n  %s\n", heat_buf);
				printf("  <-- start of file                                                 end of file -->\n");
			}
			printf("\n");

			validate_free(result);
		}
		free(paths);
		return overall_exit;
	}

	init_output_destinations();

	/* In JSON mode, mute begin callback and suppress non-JSON stdout */
	if (g_json_mode) {
		g_begin_out.muted = 1;
	} else if (g_wrote_hash_to_stderr_only) {
		/* Write deferred hash to stdout (suppressed in JSON mode) */
		write_self_hash(stdout);
	}

	/* Register begin callback if BEGIN_OUT is configured */
	if (!g_begin_out.muted) {
		validate_set_begin_callback(on_validation_begin, NULL);
	}

	const size_t max_files = get_env_max_files();

	/* Check VALIDATE_MAX_MEMORY / MAX_MEMORY env var (--max-memory override takes precedence) */
	if (validate_get_max_memory() == validate_system_memory() / 2) {
		/* No explicit --max-memory was set, check env var */
		const char* mem_env = validate_getenv(VALIDATE_ENV_MAX_MEMORY);
		if (mem_env && mem_env[0] != '\0') {
			char *endptr;
			uint64_t mem = strtoull(mem_env, &endptr, 10);
			if (*endptr == 'G' || *endptr == 'g') mem *= 1024ULL * 1024 * 1024;
			else if (*endptr == 'M' || *endptr == 'm') mem *= 1024ULL * 1024;
			else if (*endptr == 'K' || *endptr == 'k') mem *= 1024ULL;
			if (mem > 0) validate_set_max_memory(mem);
		}
	}
	/* Collect ALL files from ALL paths into a single list */
	path_list_t file_list;
	if (path_list_init(&file_list, 1024, max_files) != 0) {
		fprintf(stderr, "%sError: Out of memory\n%s", COLOR_RED, COLOR_RESET);
		free(paths);
		shutdown_output_destinations();
		return 1;
	}

	int any_directories = 0;
	for (size_t i = 0; i < path_count; i++) {
		struct stat st;
		if (stat(paths[i], &st) != 0) {
			fprintf(stderr, "%sError: Cannot access path: %s\n%s", COLOR_RED, paths[i], COLOR_RESET);
			continue;
		}

		if (S_ISDIR(st.st_mode)) {
			any_directories = 1;
			if (max_files > 0 && file_list.count == 0) {
				printf("%sNote:%s MAX_FILES=%zu (results may be truncated)\n", COLOR_YELLOW, COLOR_RESET, max_files);
			}
			/* Enable progress display for directory enumeration */
#ifdef _WIN32
			g_show_enum_progress = isatty(_fileno(stderr));
#else
			g_show_enum_progress = isatty(STDERR_FILENO);
#endif
			if (is_bundle_directory(paths[i]) || is_bagit_directory(paths[i])) {
				path_list_add(&file_list, paths[i], (size_t)st.st_size);
			} else {
				enumerate_directory(paths[i], &file_list);
			}
		} else if (S_ISREG(st.st_mode)) {
			path_list_add(&file_list, paths[i], (size_t)st.st_size);
		} else {
			fprintf(stderr, "%sWarning: Skipping unsupported path type: %s\n%s", COLOR_YELLOW, paths[i], COLOR_RESET);
		}
	}
	finish_enum_progress();
	free(paths);

	if (file_list.count == 0) {
		printf("No files found.\n");
		path_list_free(&file_list);
		shutdown_output_destinations();
		return 0;
	}

	/* Scatter large files evenly through queue unless disabled or shuffle mode */
	int should_shuffle = shuffle || (stress_iterations > 1);
	if (!no_frontload && !should_shuffle) {
		scatter_large_files(&file_list);
	}

	/* Clear screen before starting validation output (TUI will set up scrolling region) */
	if (isatty(STDERR_FILENO) && file_list.count > 1) {
		fprintf(stderr, "\033[2J\033[H");  /* Clear screen, move to top */
		fflush(stderr);
	}

	if (any_directories || file_list.count > 1) {
		fprintf(stderr, validate_tr(VALIDATE_STR_FOUND_FILES_TO_VALIDATE), file_list.count);
		fprintf(stderr, "%s\n\n", should_shuffle ? " (shuffled)" : "");
		fflush(stderr);
	} else if (!g_json_mode) {
		fprintf(stderr, "%s %s\n", validate_tr(VALIDATE_STR_CHECKING), file_list.paths[0]);
		fflush(stderr);
	}

	/* Initialize progress tracking (backed by progrez library) */
	g_file_list_ptr = &file_list;
	progress_init_new(file_list.count, file_list.total_bytes, simple_progress);

	/* Register atexit handler to restore terminal if process exits abnormally */
	if (g_tui_enabled) {
		atexit(restore_terminal_on_exit);
		/* Render initial progress bar immediately so user sees feedback */
		progress_render_force(1);
	}

	validation_counts_t counts = {0};
	validation_counts_t total_counts = {0};
	int failures = 0;
	uint64_t batch_start_ms = get_monotonic_ms();

	const size_t iterations = (stress_iterations > 0) ? stress_iterations : 1;

	for (size_t iter = 0; iter < iterations; iter++) {
		if (stress_iterations > 1) {
			/* Clear progress line before iteration message */
			if (g_tui_enabled) {
				fprintf(stderr, "\r\033[K");
			}
			printf("%s=== Stress iteration %zu/%zu ===%s\n", COLOR_CYAN, iter + 1, iterations, COLOR_RESET);
		}

		if (should_shuffle) {
			shuffle_paths(&file_list, iter + 1);
		}

		counts = (validation_counts_t){0};

		/* Reset progress for each iteration in stress mode */
		if (stress_iterations > 1 && iter > 0) {
			validate_progress_init("validate");
			validate_progress_detect_caps(isatty(STDERR_FILENO), simple_progress, (uint16_t)g_term_width);
			validate_progress_set_determinate((uint64_t)file_list.count, (uint64_t)file_list.total_bytes);
		}

		/* JSON array opening bracket */
		if (g_json_mode == 1) {
			fputs("[\n", stdout);
		}

		validate_error_t err = validate_batch(
			(const char* const*)file_list.paths,
			file_list.ids,
			file_list.count,
			(int)jobs,
			on_validation_result,
			&counts
		);

		/* JSON array closing bracket */
		if (g_json_mode == 1) {
			fputs("\n]\n", stdout);
		}

		if (err != VALIDATE_OK) {
			/* Clean up progress display before error */
			if (g_tui_enabled) {
				fprintf(stderr, "\r\033[K");
			}
			fprintf(stderr, "%sError: Validation failed: %s\n%s", COLOR_RED,
				validate_last_error() ? validate_last_error() : "unknown error", COLOR_RESET);
			progress_cleanup_new();
			path_list_free(&file_list);
			shutdown_output_destinations();
			return 1;
		}

		total_counts.valid_count += counts.valid_count;
		total_counts.invalid_count += counts.invalid_count;
		total_counts.unknown_count += counts.unknown_count;

		if (counts.invalid_count > 0) {
			failures = 1;
		}
	}

	/* Check if we were interrupted */
#if defined(_WIN32)
	int was_interrupted = validate_is_interrupted();
#else
	int was_interrupted = (g_sigint_count > 0) || validate_is_interrupted();
#endif

	/* Save counts before freeing */
	size_t total_file_count = file_list.count;
	size_t total_byte_count = file_list.total_bytes;

	/* Clean up progress display */
	progress_cleanup_new();
	g_file_list_ptr = NULL;

	path_list_free(&file_list);

	/* Use total_counts for summary in stress mode, otherwise use last counts */
	validation_counts_t* summary_counts = (stress_iterations > 1) ? &total_counts : &counts;

	/* Show summary only when multiple files were validated (single file needs no summary) */
	/* Skip summary in JSON mode — output is machine-readable */
	size_t total_processed = summary_counts->valid_count + summary_counts->invalid_count + summary_counts->unknown_count;
	if (!g_json_mode && (total_processed > 1 || was_interrupted)) {
		const char* rlm = g_rtl_enabled ? RLM : "";
		if (was_interrupted) {
			printf("\n%s%s%s%s\n", rlm, COLOR_YELLOW, validate_tr(VALIDATE_STR_SUMMARY_INTERRUPTED), COLOR_RESET);
		} else {
			printf("\n%s%s%s%s\n", rlm, COLOR_CYAN, validate_tr(VALIDATE_STR_SUMMARY_TITLE), COLOR_RESET);
		}
		if (stress_iterations > 1) {
			printf("%s  Iterations: %zu\n", rlm, stress_iterations);
		}
		if (was_interrupted) {
			printf("%s  %s %zu / %zu files\n", rlm, validate_tr(VALIDATE_STR_SUMMARY_PROCESSED), total_processed, total_file_count);
		}
		printf("%s  %-8s %s%zu%s\n", rlm, validate_tr(VALIDATE_STR_SUMMARY_VALID), COLOR_GREEN, summary_counts->valid_count, COLOR_RESET);
		if (summary_counts->invalid_count > 0) {
			printf("%s  %-8s %s%zu%s\n", rlm, validate_tr(VALIDATE_STR_SUMMARY_INVALID), COLOR_RED, summary_counts->invalid_count, COLOR_RESET);
		} else {
			printf("%s  %-8s %zu\n", rlm, validate_tr(VALIDATE_STR_SUMMARY_INVALID), summary_counts->invalid_count);
		}
		printf("%s  %-8s %zu\n", rlm, validate_tr(VALIDATE_STR_SUMMARY_UNKNOWN), summary_counts->unknown_count);

		/* Elapsed time and throughput */
		uint64_t elapsed_ms = get_monotonic_ms() - batch_start_ms;
		if (elapsed_ms > 0 && total_processed > 0) {
			double elapsed_s = (double)elapsed_ms / 1000.0;
			double files_per_sec = (double)total_processed / elapsed_s;
			double mb_per_sec = ((double)total_byte_count / (1024.0 * 1024.0)) / elapsed_s;
			printf("%s  %-8s %.1fs (%.1f files/sec, %.1f MB/s)\n", rlm, "Time:", elapsed_s, files_per_sec, mb_per_sec);
		}
	}

	/* Reset interrupt flag for potential future use */
	validate_reset_interrupt();

	shutdown_output_destinations();
	return (failures || was_interrupted) ? 1 : 0;
}
