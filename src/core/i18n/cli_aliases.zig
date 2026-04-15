//! CLI argument and environment variable alias types.
//!
//! Each locale provides a CliAliases and EnvAliases instance.
//! These are aggregated at comptime into flat StaticStringMaps
//! so that ALL locales' aliases are matched simultaneously.

/// CLI argument identifiers (matches validate_arg_t in C header).
pub const CliArg = enum(u8) {
    help = 0,
    version = 1,
    lang = 2,
    jobs = 3,
    shuffle = 4,
    stress = 5,
    no_color = 6,
    color = 7,
    simple_progress = 8,
    no_frontload = 9,
    append = 10,
    json = 11,
    ndjson = 12,
    about = 13,
};

/// Locale-specific CLI argument aliases (without -- prefix).
pub const CliAliases = struct {
    help: [:0]const u8,
    version: [:0]const u8,
    lang: [:0]const u8,
    jobs: [:0]const u8,
    shuffle: [:0]const u8,
    stress: [:0]const u8,
    no_color: [:0]const u8,
    color: [:0]const u8,
    simple_progress: [:0]const u8,
    no_frontload: [:0]const u8,
    append: [:0]const u8,
    json: [:0]const u8,
    ndjson: [:0]const u8,
    about: [:0]const u8,
};

/// Environment variable identifiers (matches validate_env_t in C header).
pub const EnvVar = enum(u8) {
    ok_out = 0,
    warn_out = 1,
    fail_out = 2,
    unknown_out = 3,
    slow_out = 4,
    debug_out = 5,
    begin_out = 6,
    max_files = 7,
    validate_debug = 8,
    no_bidi = 9,
};

/// Locale-specific environment variable aliases (full name, e.g. "FEHLER_AUS").
pub const EnvAliases = struct {
    ok_out: [:0]const u8,
    warn_out: [:0]const u8,
    fail_out: [:0]const u8,
    unknown_out: [:0]const u8,
    slow_out: [:0]const u8,
    debug_out: [:0]const u8,
    begin_out: [:0]const u8,
    max_files: [:0]const u8,
    validate_debug: [:0]const u8,
    no_bidi: [:0]const u8,
};
