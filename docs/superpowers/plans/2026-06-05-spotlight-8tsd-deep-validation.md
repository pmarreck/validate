# Spotlight `8tsd` deep validation — design proposal + implementation plan

**Date:** 2026-06-05
**Author:** validate LLM
**Re:** project-manager briefing `inbox/2026-06-05-spotlight-index-deep-validation-opportunity.md`
**Status:** proposal (investigation complete; awaiting greenlight before validator code)

## Executive summary

The briefing's core technical premise was **wrong in one load-bearing way**, which I caught by
inspecting the real bytes on Peter's machine before designing:

> **None of the Spotlight `*.db` files are SQLite.** Every `store.db`, `skg_store.db`, and
> `embedding_store.db` under `~/Library/Metadata/CoreSpotlight/` begins with magic `38 74 73 64`
> = **`8tsd`**, Apple's proprietary Spotlight store format — *not* `SQLite format 3`. `grep` for
> `SQLite format 3` across `store.db` returns **0** hits.

So the briefing's **Track A as written** ("open store.db with sqlite3, walk tables, cross-reference")
**cannot work** — there is no SQLite layer. This proposal revises Track A onto the correct
foundation: parse the `8tsd` format directly. The good news: `8tsd` is **well reverse-engineered
publicly** (Yogesh Khatri's `spotlight_parser`), and Peter's actual header bytes match that spec
exactly — so we are *not* starting from zero.

Peter's hypothesis ("forked SQLite + Apple magic") is **right in spirit, wrong in letter**: it IS a
paged store with a b-tree-like block directory (conceptually SQLite-ish), but it is Apple's own
on-disk layout, not SQLite internally.

## Verified facts (against Peter's real files)

`8tsd` header (Khatri's offsets, confirmed byte-for-byte on `Priority/index.spotlightV3/store.db`):

| Offset | Field | Peter's value |
|---|---|---|
| 0x00 | magic | `8tsd` |
| 0x04 | flags | `0x10801` |
| 0x24 | header_size | 4096 |
| 0x28 | block0_size | 16384 |
| 0x2C | block_size | 16384 |
| 0x30–0x40 | index_blocktype 0x11/0x21/0x41/0x81×2 | all 0 (V3 variant — note, not necessarily corruption) |
| 0x144 | original_path (256B) | `/System/Volumes/Data/Users/pmarreck/Library/Metadata/CoreSpotlight/Priority/index.spotlightV3/store.db` |

- **Block 0** (at offset = header_size = 4096) has magic `1mbd` ("dbm1" map block), `block0_size=0x4000`,
  `item_count=602` — the record-block directory. Matches Khatri exactly.
- Regular blocks: magic `2pbd` ("dbp2"), per-block compression (LZ4 `bv4*` @ type&0x1000, LZFSE
  `bvx*` @ &0x2000, else zlib `0x78`), varint-encoded records keyed against 0x11/0x21/0x81 tables.
- **`.ivf-vector-indexes`**: tiny (40 bytes on Peter's machine for `live.2`), a sequence of
  little-endian reference records, NOT bulk vectors. Format is **genuinely undocumented publicly**
  (confirmed dead-end via DFIR/forensics search) — true from-scratch RE for Track B.

Canonical reference: Yogesh Khatri `spotlight_parser.py`
(https://github.com/ydkhatri/spotlight_parser) — trust its struct offsets over libyal/dtformats
where they conflict (verified against Peter's bytes).

## Revised tracks

### Track A′ — `8tsd` structural-integrity validator (no IVF RE needed)  [SHIP v1]

Replace the magic-only `validateSpotlight` stub (`apple_validators.zig:352-375`) with a real
structural walk that catches corruption from the format side:

1. Parse + sanity-check the header (magic, version 8tsd vs 7tsd, header_size/block_size sane,
   `original_path` is valid UTF-8 and plausibly a path).
2. Parse block 0 (`1mbd`/`2mbd` map): verify magic, `item_count`, each directory entry's
   `offset_index * block_size` lands within the file.
3. Walk regular blocks: verify each `2pbd` signature, `physical_size`/`logical_size` ≤ block_size,
   `next_block_index` chains terminate (no cycles, no out-of-range), and **each block decompresses
   successfully** (LZ4/LZFSE/zlib by type bits) to its declared `logical_size`.
4. Emit honest depth: full structural validation = `.full` when all blocks parse+decompress;
   `okWithDepthAndWarning` for unsupported sub-variants (no silent skip).

This is the corruption surface for the stuck-state class. ~300–500 lines. Pure-Zig (we already
vendor zlib; LZ4/LZFSE blocks may need a decoder — assess: zlib-only stores may suffice for v1,
WARN on LZFSE/LZ4 blocks until a decoder is wired).

### Track A″ — orphan-tombstone cross-reference  [SHIP v1, the actual Peter bug]

The `mds_stores` `IVFVectorIndex::unlink` loop is the index trying to delete a record whose backing
file is gone (or vice-versa). Detect it WITHOUT full IVF parsing:

1. From the `8tsd` store, enumerate the record IDs / references the index believes it owns.
2. Enumerate the `.ivf-vector-indexes` and `live.N.*` rotation files actually present on disk.
3. **Cross-check:** flag store records referencing a missing index file (orphan → the unlink
   target that never dies), and index files with no owning store record (stale → garbage).
4. Report the specific dangling reference. That's the smoking gun.

Caveat: the store→IVF reference mechanism is the least-documented link. v1 may start with the
coarser "does every `live.N`/`0.ivf-vector-indexes` referenced by rotation metadata exist" check
and tighten as RE deepens.

### Track B — `.ivf-vector-indexes` format RE  [BIG SHIP, Peter-sanctioned]

From-scratch RE (no public docs):
- Disassemble `IVFVectorIndex.framework/.../IVFVectorIndex`; locate `unlink` (the error is
  `unlink:4752`), `load`/`save` paths; recover the on-disk struct via `nm`/`dwarfdump` + the
  binary's Obj-C++ class metadata.
- Diff known-good vs known-broken `.ivf-vector-indexes` (Peter's machine provides both — broken is
  the one mds_stores loops on).
- Produce `src/core/spotlight_ivf.zig` + a public format spec (defensible portfolio artifact;
  zero public prior art).

### Bonus — diagnose Peter's machine NOW  [unblocks iMessage search, months-broken]

Read-only tool: parse Peter's CoreSpotlight `8tsd` stores + IVF reference records, find the
orphan/dangling tombstone feeding the `unlink:4752` loop, print exactly which file to remove (or
which `index.spotlightV3` dir to `mdutil -E`) to break the loop. Even if throwaway, it ends a
months-long blocker.

## Architecture (per Peter's rules)

- Logic in pure-Zig core: new `src/core/spotlight_store.zig` (8tsd parser) + extend
  `apple_validators.zig` `validateSpotlight` to call it. IVF → `src/core/spotlight_ivf.zig` (Track B).
- Route through C FFI; no Zig CLI bypass.
- TDD: Peter's real `store.db` (copied read-only to fixtures, or a trimmed synthetic) as the
  known-good; a byte-corrupted copy as known-bad. Oracle cross-check against Khatri's
  `spotlight_parser.py` output where possible.
- Never touch the live files mds_stores is fighting — always operate on RAM/tmp copies.

## Suggested order (Peter said "all of these, in this order")

1. **Bonus diagnosis** (today; unblocks Peter, validates the 8tsd+IVF reading end-to-end).
2. **Track A′** (8tsd structural validator → real `validateSpotlight`).
3. **Track A″** (orphan-tombstone cross-reference).
4. **Track B** (IVF RE → spotlight_ivf.zig + spec).

## Risks / unknowns

- store→IVF reference link is the least-documented; Track A″ precision improves with Track B.
- LZFSE/LZ4 block decompression may need a Zig decoder; v1 can WARN on those blocks (no silent skip).
- IVF RE is open-ended; timebox and checkpoint.
