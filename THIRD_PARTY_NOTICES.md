# Third-Party Notices

`validate` is distributed as a single statically-linked binary that incorporates
the third-party libraries listed below. Their copyright notices and license
texts are included with every binary distribution (see the bundled `LICENSES/`
directory; in an installed artifact these live under
`share/licenses/validate/`). This file is the index; the authoritative full
texts are the per-library files in `LICENSES/`.

## Libraries with bundled license text (`LICENSES/<file>`)

| Library | License (SPDX) | File |
|---|---|---|
| zlib | Zlib | `LICENSES/zlib.txt` |
| Brotli | MIT | `LICENSES/brotli.txt` |
| libjpeg-turbo | BSD-3-Clause / IJG | `LICENSES/libjpeg-turbo.txt` |
| libjxl | BSD-3-Clause | `LICENSES/libjxl.txt` |
| libwebp | BSD-3-Clause | `LICENSES/libwebp.txt` |
| OpenJPEG | BSD-2-Clause | `LICENSES/openjpeg.txt` |
| libogg | BSD-3-Clause | `LICENSES/libogg.txt` |
| libvorbis | BSD-3-Clause | `LICENSES/libvorbis.txt` |
| libopus | BSD-3-Clause | `LICENSES/libopus.txt` |
| libopenmpt | BSD-3-Clause | `LICENSES/libopenmpt.txt` |
| minimp3 | CC0-1.0 | `LICENSES/minimp3.txt` |
| PCRE2 | BSD-3-Clause | `LICENSES/pcre2.txt` |
| SQLite3 | Public Domain | `LICENSES/sqlite3.txt` |
| cj5 | MIT | `LICENSES/cj5.txt` |
| zig-toml | MIT | `LICENSES/zig-toml.txt` |
| zig-xml | MIT | `LICENSES/zig-xml.txt` |
| zigimg | MIT | `LICENSES/zigimg.txt` |
| LibRaw | CDDL-1.0 (elected) | `LICENSES/libraw.txt`, `LICENSES/CDDL-1.0.txt` |

## ⚠️ PENDING — bundled but license text not yet vendored (legal follow-up)

These libraries are statically linked but their full license text is **not yet**
in `LICENSES/`. They must be added before paid distribution. Tracked for Peter's
decision (do not treat as compliant yet):

- **libtheora** (Theora video) — BSD-3-Clause (Xiph.Org). Add `LICENSES/libtheora.txt`.
- **libvpx** (VP8/VP9) — BSD-3-Clause **plus** the WebM "Additional IP Rights
  Grant (PATENTS)". Add `LICENSES/libvpx.txt` AND `LICENSES/libvpx-PATENTS.txt`.
- **libwavpack** — BSD-3-Clause (David Bryant). Add `LICENSES/libwavpack.txt`.
- **libape / Monkey's Audio SDK** — license asserted in a source comment only;
  **must be verified against the actual SDK** before shipping. Add
  `LICENSES/libape.txt` once confirmed.
- **uchardetz** (encoding detection) — MPL-1.1 (Mozilla-derived). Add
  `LICENSES/uchardetz.txt`.
- **z7z / compact_pro** (Peter's own sibling projects) — confirm their license
  (BSL-1.1 like validate? MIT?) and add the text.

## LibRaw CDDL-1.0 election

LibRaw is offered under **LGPL-2.1 OR CDDL-1.0**. Peter Marreck, as the
distributor of validate, elects **CDDL-1.0** for LibRaw in every validate
binary distribution. The canonical CDDL-1.0 text is bundled at
`LICENSES/CDDL-1.0.txt`; `LICENSES/libraw.txt` carries the LibRaw attribution
and election record.

This election applies **only to LibRaw**. validate's own source code and
interfaces remain licensed under the top-level Business Source License 1.1,
including its separate restrictions on third-party GUI, API, service, plugin,
and application use. The LibRaw election grants no rights in validate beyond
those BSL terms.

— Generated as part of the 2026-06-23 CODE_REVIEW legal remediation. The bundling
mechanism (installing LICENSE + LICENSES/ + this file alongside the binary) is in
place; the PENDING items above are the remaining legal completeness work.
