# macOS Spotlight `index.spotlightV3` IVF rotation deadlock — diagnosis, format notes, mitigations, and mechanistic detection

**Date:** 2026-06-05
**Author:** validate LLM (for Peter; safe to hand to another LLM/engineer)
**Machine under study:** Peter's, macOS 26.x ("Tahoe"-era), `mds_stores` `IVFVectorIndex::unlink:4752` loop; iMessage search dead for months.
**Status:** investigation complete. **No remediation performed** — all options below are for review.

> SCOPE NOTE: Everything about the `.ivf-vector-indexes` binary layout below is **reverse-engineered
> from byte-pattern inspection of one machine in ~10 minutes**. It is internally consistent and
> matches the observed failure, but it is **inference, not Apple-documented fact**. The `8tsd`
> store format, by contrast, is well-reverse-engineered publicly (Yogesh Khatri's `spotlight_parser`).
> Treat IVF-layer claims as "strong hypothesis"; treat 8tsd claims as "documented."

---

## 1. The observed failure

Unified-log signature (repeating dozens of times/sec, indefinitely):
```
mds_stores: (SpotlightIndex) [com.apple.spotlightindex:IVFVectorIndex]
  unlink:4752: IVFVectorIndex::unlink <private> failed 0 <private>
```
Symptoms: terminal/UI responsiveness loss post-reboot (FD/CPU pressure from the busy-loop), and
iMessage search returning zero results for months. `mds_stores` was at 0% CPU at the exact moment
of measurement (between bursts) but the on-disk state was **actively mutating during a 10-minute
window** (live rotation files grew from `live.7`/gen 416 to `live.10`/gen 419), confirming the loop
is live, not a stale log artifact.

---

## 2. On-disk layout

`~/Library/Metadata/CoreSpotlight/<DOMAIN>/index.spotlightV3/` for four protection domains:

| Domain | backs | store.db | n live.N | role |
|---|---|---|---|---|
| `Priority` | high-priority items | 9.8 MB | 6 | **healthy** |
| `NSFileProtectionComplete` | locked-while-locked data | 36 KB | 1 | healthy/idle |
| `NSFileProtectionCompleteUnlessOpen` | " | 36 KB | 1 | healthy/idle |
| `NSFileProtectionCompleteUntilFirstUserAuthentication` | **Messages/iMessage** (avail after first unlock) | **559 MB** | **8→11 climbing** | **BROKEN** |

Each domain dir contains:
- `store.db` (+ `.store.db` shadow): the **`8tsd`** metadata store (NOT SQLite — see §3).
- `0.ivf-vector-indexes`: the **committed** IVF reference record.
- `live.N.ivf-vector-indexes`: **rotation snapshots**, N increasing. Each is a tiny (8–40 byte)
  reference record, NOT bulk vector data.
- plus classic Spotlight sidecars (`0.indexHead`, `0.indexIds`, `0.directoryStoreFile`, …).

---

## 3. The `8tsd` store format (DOCUMENTED — Khatri `spotlight_parser`, verified vs Peter's bytes)

All `*.db` here begin with magic `38 74 73 64` = `"8tsd"` (NOT `SQLite format 3` — grep returns 0).
It is a **paged store** (conceptually SQLite-like: a b-tree-ish block directory), with Apple's own layout.

Header (little-endian; offsets per Khatri, confirmed on Peter's files):
| Off | Field | Notes |
|---|---|---|
| 0x00 | magic `8tsd` | (`7tsd` = older v1 with shifted offsets) |
| 0x04 | flags | Peter: `0x10801` |
| 0x24 | header_size | 4096 |
| 0x28 | block0_size | 16384 (Priority) / 557056 (NSFPCUFUA) |
| 0x2C | block_size | 16384 |
| 0x30–0x40 | index_blocktype 0x11/0x21/0x41/0x81×2 | all 0 in these V3 stores |
| 0x144 | original_path (256B UTF-8) | decodes to the literal file path — **good cheap integrity signal** |

Block 0 at offset `header_size`: magic `1mbd`/`2mbd`, `u32 item_count`, then 16-byte entries
`<QII>` = (last_id_in_block, offset_index, dest_block_size). Regular blocks: magic `2pbd`, per-block
compression (LZ4 `bv4*` if type&0x1000, LZFSE `bvx*` if &0x2000, else zlib `0x78`). Records are
Spotlight-custom-varint encoded, keyed against the 0x11/0x21/0x81 dictionary tables.

**Peter's 559 MB store is structurally coherent:** header valid, `original_path` clean, block-0
`1mbd` with `item_count=34104`, and `item_count × block_size = 558,759,936 ≈ file size (0.999)`.
**So the store.db is NOT torn.** The fault is in the IVF reference layer, not the metadata store.

Canonical ref: https://github.com/ydkhatri/spotlight_parser (trust its offsets over libyal/dtformats).

---

## 4. The `.ivf-vector-indexes` reference record (REVERSE-ENGINEERED — hypothesis)

Decoded as a sequence of little-endian `u32`:
```
[ generation, MAGIC, (id, type), (id, type), ..., (0, 0)? ]
  generation : u32, monotonically increasing per write
  MAGIC      : 0x015F1DA6 (23010726) constant in every file (format/version stamp)
  (id,type)  : live index-entry references; type seen = 655378 (0x000A0012)
  trailing (0,0) : padding/terminator (present in some, absent in others)
```
`0.ivf` = committed state (all domains at generation 1, `live_ids=[]`). `live.N` = rotation log;
each finalize attempt writes a new `live.N+1` with the current live set, then *should* fold into `0`.

### Evidence table (Peter's machine, 2026-06-05)

| Domain | committed gen | max live gen | GAP | terminal live_ids | verdict |
|---|---|---|---|---|---|
| Priority | 1 | 58 | 57 | `[]` (drained at gen 58) | healthy |
| NSFProtComplete | 1 | 2 | 1 | `[]` | healthy |
| NSFProtCompleteUnlessOpen | 1 | 2 | 1 | `[]` | healthy |
| **NSFPCUFUA (Messages)** | 1 | **419 (climbing)** | **418** | **`[532]` never drains** | **DEADLOCK** |

Per-generation live set for NSFPCUFUA (chronological by gen):
```
gen 243: [532, 1054]
gen 245: [532, 533, 1054]
gen 405: []
gen 406: [532, 1054]
gen 413: [532, 533, 1054]
gen 414: [532, 1054]
gen 415: [532]
gen 416: [532]
gen 417: [532]
gen 418: [532]
gen 419: [532]      <- still climbing during observation
```

### Interpretation
- **A healthy domain drains:** Priority reaches its highest generation (58) with `live_ids=[]` — the
  work completed and committed.
- **The broken domain cannot drain ID `532`:** every recent generation (415–419) carries exactly
  `[532]` and the generation counter keeps climbing with no progress. `IVFVectorIndex::unlink:4752`
  is failing to remove entry 532; each failed attempt rotates a new `live.N`. Classic **liveness
  bug / spin-deadlock**: monotonic counter advance + zero state progress.
- ID 532 is the "stuck tombstone": referenced-but-unremovable. (533/1054 churn and eventually clear;
  532 is wedged.)

---

## 5. Mitigations (for Peter to choose; risk/cost spelled out)

| # | Action | Mechanism | Risk | Cost | Reversible? |
|---|---|---|---|---|---|
| M1 | **Full reindex**: `sudo mdutil -i off /` → `sudo mdutil -E /` → `sudo mdutil -i on /` | Apple-sanctioned; nukes & rebuilds ALL Spotlight indexes | Low (Apple-supported). Search degraded until reindex done. | High time: hours of CPU to reindex a full disk | Index rebuilds from scratch; no user data lost |
| M2 | **Domain-surgical**: quit Spotlight indexing, `mv NSFPCUFUA/index.spotlightV3 ~/.Trash/`, let mds rebuild just that domain | Removes only the broken domain; others untouched | Med — relies on this RE diagnosis that NSFPCUFUA is the sole culprit; backs Messages search | Low-Med: only the Messages domain reindexes | Yes — it's in Trash; restorable |
| M3 | **Micro-surgical**: remove only the stuck `live.N`/`0.ivf` for NSFPCUFUA | Tries to break the rotation without full domain rebuild | **High** — depends entirely on RE'd semantics; could leave store↔IVF inconsistent and make it worse | Lowest if it works | Yes if files trashed not deleted, but state may be incoherent |
| M4 | **Do nothing / monitor** | — | The loop continues: periodic CPU/FD pressure, no iMessage search | None now, ongoing pain | n/a |

**Recommendation for Peter:** M1 is the safe default (doesn't trust my RE). M2 is the targeted
option with the best effort/reward *if* the RE diagnosis is accepted (it's well-supported). M3 only
with a full backup and acceptance of risk. **None should be run without Peter's explicit go.**

Pre-req for any: Time Machine / backup current, since Spotlight state is being mutated.

---

## 6. What validate can detect mechanistically (the shippable insight)

This failure is a **generic, code-checkable pattern**, not Messages-specific. validate can flag
"Spotlight index in a stuck/deadlock-looking state" with zero IVF RE risk, purely from observable
invariants:

### Check A — committed/live generation gap (liveness)
For each `index.spotlightV3` domain: `gap = max(live.N gen) - committed(0.ivf) gen`.
A large gap with a **non-empty, non-draining terminal live set** = stuck rotation. Healthy domains
either have small gaps or drain to `live_ids=[]` at the top generation.
- WARN threshold candidate: gap > (small constant, e.g. 32) AND terminal live_ids non-empty.
- FAIL/strong-WARN: gap > 256 AND the same id present in the last K generations (never drains).

### Check B — never-draining reference (the tombstone)
Compute the set of ids present in the **highest-generation** `live.N`. If any id persists across the
last K consecutive generations (e.g. K=8) without disappearing, flag it as a stuck/undead reference.
This is the `unlink` target. Purely set-arithmetic over the decoded reference records — no risk.

### Check C — rotation-count explosion
`n live.N files` far exceeding peer domains (here 11 vs 1) is a cheap smoke signal of a domain that
can't finalize.

### Check D — `8tsd` structural integrity (independent, generally useful)
Header sane (magic, header_size/block_size, original_path is valid UTF-8 path), block-0 `1mbd`/`2mbd`
map present, `item_count × block_size ≈ file_size`, regular blocks `2pbd` with sizes ≤ block_size and
`next_block_index` chains that terminate without cycles, and per-block decompress success. Catches
torn/truncated stores (a *different* corruption class than the deadlock).

### Generalization beyond Spotlight
The deadlock heuristic — **"a monotonically advancing generation/sequence counter combined with a
non-draining work set"** — is a reusable signature for *any* rotation/journal/WAL-like structure
(other Apple caches, app journals, etc.). Worth framing the validate check generically:
`detectStuckRotation(committed_gen, live_gens[], live_sets[])`.

---

## 7. Proposed validate deliverables (no machine action; pure code + tests)

1. `src/core/spotlight_store.zig` — `8tsd` header + block-0 + block-walk structural validator (Check D).
2. `src/core/spotlight_ivf.zig` — decode `.ivf-vector-indexes` reference records; expose
   `(generation, magic_ok, live_ids[])`.
3. Deadlock heuristics (Checks A/B/C) over a `index.spotlightV3` directory → health verdict.
4. Wire into `validateSpotlight` (`apple_validators.zig:352-375`, currently magic-only) as a
   deeper-than-structural path; and/or a `validate --spotlight-health <dir>` report subcommand.
5. **Test fixtures** (synthetic, checked-in): a "healthy" set (small gap, draining live set) and a
   "deadlock" set (huge gap, never-draining id across K generations) — built byte-for-byte to the
   §4 schema. Plus a torn-`8tsd` fixture for Check D. Red-proof each heuristic.

## 8. Open questions / caveats for whoever picks this up
- IVF `type` field meaning (`655378` = `0x000A0012`) unconfirmed — may encode dimension/quantizer.
- Whether `0.ivf` committed-gen ever advances past 1 on a healthy machine (all 4 domains here = 1;
  need a second machine to confirm 1 is truly the baseline vs already-stuck-everywhere).
- The exact store→IVF id linkage (does `8tsd` store reference IVF ids 532/533/1054?) — needs the
  store record decode (Track B depth) to fully close; the deadlock heuristic does NOT require it.
- `.ivf-vector-indexes` layout is single-machine RE; validate before generalizing.

## 9. Reproduce the diagnosis (read-only, safe)
```bash
cd ~/Library/Metadata/CoreSpotlight
for dom in */index.spotlightV3; do
  for f in "$dom"/*.ivf-vector-indexes; do
    python3 - "$f" <<'PY'
import sys,struct
b=open(sys.argv[1],'rb').read(); v=list(struct.unpack('<%dI'%(len(b)//4), b[:len(b)//4*4]))
gen=v[0]; ids=[v[i] for i in range(2,len(v)-1,2) if v[i]!=0]
print(f"{sys.argv[1]:70s} gen={gen:4d} live_ids={ids}")
PY
  done
done
```
Compare generation spread + terminal live set per domain; the broken one has a huge gap and a
never-draining id.
