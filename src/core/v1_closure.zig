//! v1 production-closure hard-gate ("physics over policy", Peter 2026-08-06).
//!
//! CONTROL FILE (MFIC): this file is blessed-hashed by
//! tests/cli/v1_closure_control — any edit here must be accompanied by a
//! deliberate blessing update in blessed_hashes.txt, making every change a
//! conspicuous two-file diff for human review. Keep this file SMALL and
//! rarely changed.
//!
//! Layer 1 (this file): the build MANIFEST itself is embedded at comptime and
//! scanned for forbidden dependency declarations. Re-adding a forbidden dep
//! to build.zig.zon fails compilation of every consumer of validate_core with
//! a message naming the remediation — no agent memory, hook, or review
//! required. The scan matches the exact dep-declaration pattern
//! (`.name = .{`), so prose comments ABOUT removed deps never trip it.
//!
//! Layer 2 (scripts/audit-first-party-closure, run by the
//! first_party_closure_audit CLI test): the built binary's symbols and the
//! complete Nix runtime closure are scanned for forbidden store paths and
//! link edges — catching artifact-level reintroduction the manifest scan
//! cannot see (system libs, vendored objects).
//!
//! The forbidden list GROWS as first-party replacements land; each addition
//! is a decoder made unnecessary. History: openjpeg + direct libjxlz
//! (2026-08-14, JP2/JXL via tiffz.jpegz), libraw (2026-08-15, ARW/CR2/NEF
//! via tiffz + jpegz; vendor payloads are rawz milestones).

const std = @import("std");

/// Dependency-declaration patterns that must never reappear in build.zig.zon.
/// Pattern form is `.<dep-key> = .` — the start of a zon dependency entry.
const forbidden_manifest_patterns = [_][]const u8{
    ".libraw = .", // LibRaw (LGPL/CDDL) — oracle-only, never shipped
    ".openjpeg = .", // OpenJPEG — JP2 is pure-Zig jp2z via tiffz.jpegz
    ".libjxlz = .", // direct pin forbidden — single instance via tiffz.jpegz
    ".jpegz = .", // direct pin forbidden — single instance via tiffz (see #32)
    ".lzwz = .", // direct pin forbidden — single shared instance via tiffz
    ".rawspeed = .", // never a dep; listed so it cannot become one
};

comptime {
    // The manifest is several KB and indexOf iterates it per pattern; the
    // default 1000-branch comptime quota aborts the scan before it can match
    // (witnessed during gate bring-up). Budget generously — this runs once
    // per compilation and is trivially cheap in wall-clock.
    @setEvalBranchQuota(2_000_000);
    const manifest = @embedFile("build_manifest");
    for (forbidden_manifest_patterns) |pattern| {
        if (std.mem.indexOf(u8, manifest, pattern) != null) {
            @compileError("v1 production-closure violation: forbidden dependency pattern '" ++
                pattern ++ "{' found in build.zig.zon. Oracle libraries stay OUTSIDE the " ++
                "build graph (dev/test only), and single-instance modules (jpegz/libjxlz/" ++
                "lzwz) are consumed through tiffz. If this reintroduction is deliberate, " ++
                "it requires editing src/core/v1_closure.zig AND re-blessing it in " ++
                "blessed_hashes.txt — a two-file diff Peter reviews.");
        }
    }
}

test "v1 closure: manifest is embedded and non-empty (gate is armed)" {
    // The comptime scan above only bites if this file is analyzed and the
    // embed resolves. This test proves both: an empty or missing manifest
    // embed would be a silently disarmed gate (the jpegz lesson: assert the
    // gate CAN see its target, not merely that it found nothing).
    const manifest = @embedFile("build_manifest");
    try std.testing.expect(manifest.len > 1000);
    // And the manifest is the real one: it must declare the tiffz dep that
    // every build genuinely requires.
    try std.testing.expect(std.mem.indexOf(u8, manifest, ".tiffz = .") != null);
}
