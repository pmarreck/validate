# Hybrid BlipBuffer Specification (Zig / C / Swift FFI)

> **Note on naming.** "BLIP" here refers strictly to the
> **byte-length integer-prefix** core — a self-delimiting varint length
> prefix, like LEB128 or Protobuf's varint. It does NOT refer to the
> separate printable-binary visual encoding that has historically also
> been called BLIP in `printable_binary` / `mini_blar`.
>
> The two concerns share a name today and should be split into separate
> projects:
>
> - **BLIP** — the length-prefix spec + reference encoder/decoder library.
> - **blar** — the BLIP archiver (uses BLIP as its framing format).
> - **mini_blar** — the embedded subset / size-constrained variant of blar.
>
> See `PLAN.md` for the open project-split task.

---

## 1. Purpose

A representation for binary buffers passed across the
**Zig ↔ C ↔ Swift** FFI surface that:

- Minimizes copying.
- Supports arbitrary binary data (NUL-safe).
- Preserves explicit ownership semantics.
- Enables optional zero-copy interop with C string APIs (`char *`).
- Avoids endianness ambiguity in the serialized form.

This is a **byte-buffer** spec, not a string spec. UTF-8-enforced text
is a separate concern — see §13.

---

## 2. Design Principles

1. **One canonical serialized representation:** BLIP-prefixed length + raw bytes.
2. **Runtime uses decoded views:** `ptr + len` for fast access.
3. **Ownership is explicit:** never inferred from `char *`.
4. **C compatibility is optional:** the trailing NUL is an interop affordance, not authoritative.
5. **Parsing happens at boundaries:** never repeatedly in hot paths.
6. **Verb consistency at the API surface:** `_view()` for borrows, `_take_owned()` for transfers, `_to_owned_copy()` when a copy is required. Don't conflate.

---

## 3. Terminology

| Term         | Meaning |
|--------------|---------|
| BLIP prefix  | Variable-length integer encoding of length (varint, LEB128-style) |
| Payload      | Raw byte sequence |
| Sentinel     | Optional trailing `\0` |
| View         | Non-owning `ptr + len` |
| Owned        | Must be freed via explicit function |

---

## 4. Canonical Serialized Format

### 4.1 Binary-safe buffer

```
[ BLIP(length) ][ bytes... ]
```

### 4.2 C-compatible buffer

```
[ BLIP(length) ][ bytes... ][ 0 ]
```

### Rules

- `length` excludes the trailing NUL.
- Payload MAY contain interior `0` bytes.
- Trailing NUL is optional and not authoritative.
- BLIP prefix is the only source of truth for length.
- The serialized form contains **no multi-byte numeric fields beyond the
  varint prefix itself**, so endianness is irrelevant.

---

## 5. Runtime Representation

### 5.1 Core view type (C)

```c
typedef struct {
  const uint8_t *ptr;
  size_t len;
} ByteSlice;
```

Zig equivalent: `[]const u8`.

If a NUL terminator is guaranteed, Zig types can express that with
`[:0]const u8`. **The two are different types**, and the FFI surface
should not silently coerce. If a function returns NUL-terminated bytes,
expose that explicitly in the wrapper.

### 5.2 Parsed BLIP view (C)

```c
typedef struct {
  const uint8_t *base;        // start of allocation, including BLIP prefix
  const uint8_t *bytes;       // start of payload, == base + prefix_len
  size_t len;                 // payload length
  size_t prefix_len;          // bytes consumed by BLIP prefix
  bool has_sentinel;          // true if a trailing NUL is present at bytes[len]
} BlipBufferView;
```

`base` is retained alongside `bytes` so that, if the parent allocation
was transferred (see §8), the consumer knows which pointer to free.
When `base == bytes` the buffer was constructed without an in-place
BLIP prefix (view-of-existing-bytes).

---

## 6. Ownership Model

### 6.1 Owned buffer (C)

```c
typedef struct {
  uint8_t *ptr;
  size_t len;
  void (*deinit_fn)(void *ctx, uint8_t *ptr);
  void *ctx;
} OwnedBuffer;
```

(The previous `owner_id: uint8_t` field has been removed pending a
concrete use case — pool routing, debug tagging, etc. would all be
better served as a separate side-table than as a field on every owned
buffer.)

### 6.2 Rules

- `deinit_fn` MUST be used to free.
- `free(ptr)` MUST NOT be assumed valid (the bytes may have come from
  jemalloc, mimalloc, a slab pool, an mmap region, etc.).
- Ownership is never implicit.
- **Thread-safety contract:** `deinit_fn` MAY be called from a thread
  other than the one that produced the buffer. Implementations MUST
  ensure their `ctx` and the underlying allocator are thread-safe, OR
  the producer MUST document that the buffer is thread-pinned (in which
  case the consumer MUST hand it back to the originating thread for
  destruction). The default expectation is "freely movable across
  threads"; thread-pinning is the special case and must be flagged.

---

## 7. FFI Usage Patterns

### 7.1 Zig → C → consumer (e.g. Swift)

Borrowed view:

```c
typedef struct HybridBuffer HybridBuffer;

const char *hybrid_buffer_view(const HybridBuffer *);   // borrowed pointer
size_t      hybrid_buffer_len(const HybridBuffer *);
void        hybrid_buffer_destroy(HybridBuffer *);
```

Rules:

- Returned pointer is borrowed.
- Caller MUST NOT call `free()`.
- The pointer is valid until `hybrid_buffer_destroy` runs.

Take-owned (zero-copy, layout-aware — see §8):

```c
char *hybrid_buffer_take_owned(HybridBuffer *);    // NULL if layout incompatible
char *hybrid_buffer_to_owned_copy(HybridBuffer *); // always succeeds, always copies
```

The two functions are deliberately split. A single function whose cost
is layout-conditional (sometimes copies, sometimes doesn't) is hostile
to performance reasoning and to debugging tools (helgrind, asan,
leak-tracking).

---

### 7.2 Foreign C → Zig

#### A. Borrowed

```c
const char *get();
```

Zig: `std.mem.span(ptr)`.

#### B. Owned with custom free

```c
char *get();
void  lib_free(char *);
```

Wrap as `OwnedBuffer` whose `deinit_fn` calls `lib_free`.

#### C. Owned with libc free

```c
char *get();
```

Wrap as `OwnedBuffer` whose `deinit_fn` calls `free`.

---

### 7.3 Zig → C → Swift specifically

Swift bridges naturally to the patterns above:

- **Swift → C (borrow):** `string.withCString { ptr in c_fn(ptr, len) }`
  already produces the `(UnsafePointer<CChar>, Int)` shape that maps
  to `ByteSlice`. No copy.
- **C → Swift (ownership transfer):**
  `Data(bytesNoCopy: ptr, count: len, deallocator: .custom { p, n in lib_free(p) })`
  is the Swift-side analog of `OwnedBuffer`. Built-in zero-copy with
  custom dealloc. The `deinit_fn` lives inside the deallocator
  closure.
- **C → Swift (borrow that survives the call):** wrap in
  `UnsafeBufferPointer<UInt8>` and document the lifetime contract.

For consumers that need `String` (SwiftUI `Text`, etc.), the copy
happens at the `String(bytes:encoding:)` step — which is unavoidable if
the consumer renders text. BLIP doesn't help that case; it helps the
case where bytes flow through Swift WITHOUT a `String`
materialization (forwarding an extracted thumbnail, a decompressed
payload, a serialized blob).

---

## 8. Zero-Copy C Ownership Transfer

### 8.1 Supported allocation layout

```
[ metadata block ] -> [ bytes... ][ 0 ]
                     ^
                     own malloc base — independently free()-able
```

Metadata block and bytes are **separate allocations**. Freeing the
metadata leaves the bytes intact and `free()`-able by the consumer.

### 8.2 Two transfer APIs

```c
// Returns NULL if the layout is incompatible (single contiguous allocation).
// On success: the allocation is now caller-owned and must be free()'d.
char *hybrid_buffer_take_owned(HybridBuffer *);

// Always succeeds. Always copies the bytes into a fresh malloc'd buffer.
// Use when the caller doesn't care whether a copy happens.
char *hybrid_buffer_to_owned_copy(HybridBuffer *);
```

### 8.3 Unsupported layout

```
[ metadata ][ bytes... ][ 0 ]      // single allocation
```

In this layout `hybrid_buffer_take_owned` returns NULL. Callers that
need owned bytes must use `hybrid_buffer_to_owned_copy` instead.

---

## 9. BLIP Parsing

### 9.1 Required function

```c
bool blip_parse(
  const uint8_t *input,
  size_t input_len,
  size_t *out_len,
  size_t *out_prefix_len
);
```

### 9.2 Rules

- MUST validate the encoding (continuation-bit framing, no overlong
  sequences).
- MUST detect overflow (length larger than `SIZE_MAX`).
- MUST NOT read past `input + input_len`.
- Returns `false` on any failure; `*out_len` and `*out_prefix_len` are
  undefined on failure.

---

## 10. Performance Model

| Operation      | Cost |
|----------------|------|
| BLIP parse     | O(prefix size) — typically 1–2 byte reads |
| `strlen`       | O(n) — never call on a BLIP buffer |
| ptr+len access | O(1) |

### Principle

Parse once at the boundary. Use ptr+len internally.

---

## 11. Invariants

- BLIP length is canonical.
- Runtime never trusts `strlen`.
- Ownership is always explicit.
- `char *` is a view unless explicitly transferred via `take_owned`.
- Copying occurs only when required for ownership change OR when
  `to_owned_copy` is called explicitly.
- Multi-byte numeric fields in the wire form: none. Endianness is a
  non-concern at the protocol level.

---

## 12. Anti-Patterns (Forbidden)

- Calling `free()` on a non-owned pointer.
- Inferring ownership from pointer type.
- Using `strlen` when a BLIP length exists.
- Mixing prefix formats in the same API surface.
- Implicit ownership transfer.
- Single-function APIs whose cost is layout-conditional (always split:
  one zero-copy path that can fail, one always-copy path that always
  succeeds).

---

## 13. Buffer vs String

This spec describes a **binary-safe byte buffer**. It does NOT enforce
UTF-8. Layered atop, a separate `HybridString` type can wrap a
`HybridBuffer` and add UTF-8 well-formedness validation at the
boundary. Consumers that want UTF-8 guarantees should use the string
wrapper; consumers handling arbitrary binary (extracted image bytes,
compressed payloads, serialized blobs) should use the buffer type
directly.

The two types share the wire format and the ownership model; only the
boundary-time validation differs.

---

## 14. Recommended Usage Strategy

| Layer          | Representation |
|----------------|----------------|
| Storage / wire | BLIP + bytes |
| FFI boundary   | BLIP → ptr+len |
| Runtime        | ptr+len |
| C interop      | optional NUL |
| Ownership      | explicit `_view` / `_take_owned` / `_to_owned_copy` APIs |
| Threading      | document per-allocator; default = freely movable |

---

## 15. Adoption Question (validate-specific)

Before wiring this through validate's entire FFI surface, prototype on
**one** call and measure. Validate's FFI hot path isn't string passing —
it's mmap'd file scanning + per-validator scratch (already routed
through arena + diverting allocator). Path strings, format names, and
error messages are tiny and not in the inner loop.

Suggested prototype: `validate_get_format_name`. Wire it with
`BlipBuffer`, measure (a) memory churn, (b) heap fragmentation, (c) p99
latency vs the trivial `(const char*, size_t)` baseline. If it pays for
itself, expand.

For *cross-project* infra (printable_binary / ffpw / z7z / validate /
entropy_shield as a stack), the design pays for itself only if buffer
handles flow across those projects in real workloads — which they
don't currently. The §8 ownership-transfer pattern is independently
useful even if the rest of BLIP isn't adopted.

---

## 16. Final Note

This design intentionally avoids a universal string type.

Instead:

- One canonical serialized format (BLIP varint length + bytes).
- One canonical runtime representation (ptr + len).
- Explicit ownership adapters (`_view` / `_take_owned` / `_to_owned_copy`).
- A clean Swift bridge via `Data(bytesNoCopy:count:deallocator:)`.

This minimizes bugs, avoids unnecessary copies, and preserves
performance.
