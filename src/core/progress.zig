//! C FFI wrapper around progrez pure-logic modules.
//! Holds global ProgrezState + TerminalCaps, exports C functions
//! for cli/main.c to call. No threads, no I/O — just state + rendering.

const std = @import("std");
const progrez = @import("progrez");
const core = progrez.core;
const terminal = progrez.terminal;
const render = progrez.render;

/// Global progress state (single-instance, managed by the CLI).
/// Thread safety: all progress functions are called from the main thread only
/// (cli/main.c). Worker threads never call progress functions directly.
var g_state: core.ProgrezState = core.ProgrezState.init("validate");

/// Cached terminal capabilities.
var g_caps: terminal.TerminalCaps = .{
    .is_tty = false,
    .unicode = true,
    .truecolor = false,
    .color_256 = false,
    .color_16 = false,
    .width = 80,
};

/// Cumulative counters (main.c calls update per-file; we accumulate).
var g_files_done: u64 = 0;
var g_bytes_done: u64 = 0;

// ── C-exported functions ──────────────────────────────────────────────

/// Initialize the progress state with a label.
export fn validate_progress_init(label: [*:0]const u8) void {
    const slice = std.mem.span(label);
    g_state = core.ProgrezState.init(slice);
    g_state.start_time_ns = std.time.nanoTimestamp();
    g_state.sparkline_enabled = true;
    g_files_done = 0;
    g_bytes_done = 0;
}

/// Detect and cache terminal capabilities.
/// When simple=true, forces ASCII mode (no unicode, no color).
export fn validate_progress_detect_caps(is_tty: bool, simple: bool, width: u16) void {
    if (simple) {
        g_caps = terminal.TerminalCaps.detect(.{
            .progrez_style = "ascii",
            .no_color = null,
            .colorterm = null,
            .term = null,
            .wt_session = null,
            .is_tty = is_tty,
            .width = width,
        });
    } else {
        // Read real env vars for accurate capability detection
        g_caps = terminal.TerminalCaps.detect(.{
            .progrez_style = getOptionalEnv("PROGREZ_STYLE"),
            .no_color = getOptionalEnv("NO_COLOR"),
            .colorterm = getOptionalEnv("COLORTERM"),
            .term = getOptionalEnv("TERM"),
            .wt_session = getOptionalEnv("WT_SESSION"),
            .is_tty = is_tty,
            .width = width,
        });
    }
}

/// Set determinate mode with known totals.
export fn validate_progress_set_determinate(files: u64, bytes: u64) void {
    g_state.setDeterminate(files, bytes);
}

/// Set indeterminate mode (spinner).
export fn validate_progress_set_indeterminate() void {
    g_state.setIndeterminate();
}

/// Record completion of one file with the given byte size.
/// Accumulates internally (progrez wants cumulative values).
export fn validate_progress_update(file_bytes: u64) void {
    g_files_done += 1;
    g_bytes_done += file_bytes;
    const now_ns = std.time.nanoTimestamp();
    g_state.recordUpdate(g_bytes_done, g_files_done, now_ns);
}

/// Render the progress bar line into the caller's buffer.
/// Returns the number of bytes written. The output is NOT null-terminated.
export fn validate_progress_render_line(buf: [*]u8, buf_size: usize, width: u16) usize {
    if (buf_size == 0) return 0;

    // Update width in caps for this render (terminal may have resized)
    var caps = g_caps;
    caps.width = width;

    const now_ns = std.time.nanoTimestamp();
    const slice = buf[0..buf_size];
    const rendered = render.renderLine(&g_state, caps, now_ns, slice, render.GradientColors.default);
    return rendered.len;
}

// ── Helper ────────────────────────────────────────────────────────────

fn getOptionalEnv(name: [*:0]const u8) ?[]const u8 {
    const val = std.c.getenv(name);
    if (val) |v| {
        return std.mem.span(v);
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────────────────

test "progress: init and set determinate" {
    validate_progress_init("test");
    validate_progress_set_determinate(100, 50000);

    try std.testing.expectEqual(core.Mode.determinate, g_state.mode);
    try std.testing.expectEqual(@as(?u64, 100), g_state.files_total);
    try std.testing.expectEqual(@as(?u64, 50000), g_state.bytes_total);
}

test "progress: update accumulates" {
    validate_progress_init("test");
    validate_progress_set_determinate(10, 10000);

    validate_progress_update(1000);
    try std.testing.expectEqual(@as(u64, 1), g_files_done);
    try std.testing.expectEqual(@as(u64, 1000), g_bytes_done);

    validate_progress_update(2000);
    try std.testing.expectEqual(@as(u64, 2), g_files_done);
    try std.testing.expectEqual(@as(u64, 3000), g_bytes_done);
    try std.testing.expectEqual(@as(u64, 2), g_state.files_processed);
    try std.testing.expectEqual(@as(u64, 3000), g_state.bytes_processed);
}

test "progress: render_line produces non-empty output for determinate" {
    validate_progress_init("validate");
    validate_progress_detect_caps(true, true, 80); // simple/ASCII mode
    validate_progress_set_determinate(100, 50000);

    // Simulate a few updates
    validate_progress_update(5000);
    validate_progress_update(5000);
    validate_progress_update(5000);

    var buf: [2048]u8 = undefined;
    const len = validate_progress_render_line(&buf, buf.len, 80);

    // Should have rendered something
    try std.testing.expect(len > 0);

    // Should contain the label
    const output = buf[0..len];
    try std.testing.expect(std.mem.indexOf(u8, output, "validate") != null);
}

test "progress: detect_caps simple mode disables unicode" {
    validate_progress_detect_caps(true, true, 120);
    try std.testing.expect(!g_caps.unicode);
    try std.testing.expect(!g_caps.truecolor);
    try std.testing.expect(g_caps.is_tty);
    try std.testing.expectEqual(@as(u16, 120), g_caps.width);
}

test "progress: indeterminate mode renders" {
    validate_progress_init("scanning");
    validate_progress_detect_caps(true, true, 80);
    validate_progress_set_indeterminate();

    var buf: [2048]u8 = undefined;
    const len = validate_progress_render_line(&buf, buf.len, 80);

    // Indeterminate should render something (spinner + label)
    try std.testing.expect(len > 0);
}
