# Watchman → system-wide fork/FD exhaustion — diagnosis & mitigations

**Date:** 2026-05-30. macOS 26.5 (Tahoe), nix-darwin (NOT homebrew).

## Symptom
System slowly becomes unable to `fork()` *anything* — terminal can't finish
rendering its login art, every command hangs or gets SIGTERM'd, eventually even
`shutdown` can't run → force-reboot required. Builds up over time; a reboot
clears it. Classic per-UID process / FD exhaustion where `fork()` blocks
(EAGAIN) instead of failing fast.

## Root cause
Watchman auto-watches every project under `~/Documents-CloudManaged/` (30+
projects). Known failure mode — facebook/watchman#1306 "Watchman starting
thousands of processes on macOS": a runaway daemon spawns thousands of
processes and drains the shared kernel FD pool (`kern.maxfiles`), so *every*
process's `open()`/`fork()` starts blocking. One daemon wedges the whole box.

Confirmed NOT memory (29 GB free) and NOT disk (248 GB free) at failure time.
Ceilings are already high (`kern.maxprocperuid=10666`, `kern.maxfiles=10485760`)
— so this is a genuine *leak climbing to huge numbers*, not a low cap. That's
why the fix is (a) reduce watch load and (b) **warn on the climb**, not raise
the ceiling.

## Mitigation 1 — reduce watch load (per-project `.watchmanconfig`)
`validate/.watchmanconfig` ignores high-churn/generated trees: `.git`,
`.git-old`, `.jj`, `.zig-cache`, `zig-cache`, `zig-out`, `zig-pkg`, `deps`,
`node_modules`, `result`, `result-win`, `.direnv`, `.codescan`. Plus
`fsevents_latency`/`settle` to batch notifications.

To apply to ALL 30+ projects at once, use the **global** config instead (below).

## Mitigation 2 — GLOBAL config via nix-darwin (preferred; declarative)
Watchman's compiled-in global config path is `/etc/watchman.json` (verified via
`strings` on the nix store binary). Manage it declaratively in your nix-darwin
configuration so it survives rebuilds and applies to every watched root:

```nix
# in your nix-darwin configuration.nix / flake module
environment.etc."watchman.json".text = builtins.toJSON {
  ignore_dirs = [
    ".git" ".git-old" ".jj" ".zig-cache" "zig-cache" "zig-out" "zig-pkg"
    "deps" "node_modules" "target" "build" "dist" "result" "result-win"
    ".direnv" ".codescan" ".cache" "_build" "vendor"
  ];
  fsevents_latency = 0.1;
  settle = 300;
  gc_age_seconds = 600;       # reap cursor state for idle dirs after 10 min
  gc_interval_seconds = 86400;
};
```
Then `darwin-rebuild switch` and `watchman shutdown-server` (it re-reads config
on next watch). NOTE: confirm these key names against your watchman version's
docs — `ignore_dirs`, `fsevents_latency`, `settle`, `gc_age_seconds`,
`gc_interval_seconds` are all documented config keys, but validate before
relying on them.

Non-nix fallback (one-time, needs sudo):
`sudo cp validate/.watchmanconfig /etc/watchman.json` (after broadening
ignore_dirs as above).

## Mitigation 3 — warn BEFORE the wall (dotfiles/bin/resource-climb-monitor)
Background sampler that logs `$TMPDIR/resource-climb.tsv` and fires a native
macOS `osascript` desktop notification the first time any metric crosses
WARN (60%) / ALARM (80%) of its ceiling — or watchman proc count exceeds
50 (WARN) / 200 (ALARM); healthy is 1–2. State-tracked so it notifies once per
threshold, no spam. Run it from a login item or `launchd` agent for always-on
protection:
```
resource-climb-monitor [interval_seconds]   # default 20
# stop: touch $TMPDIR/resource-climb.stop
```

## Recovery when already wedged (can't fork)
`exec watchman shutdown-server` — `exec` replaces the shell's process image
(no fork). If even that fails: Force-Quit GUI apps (⌘⌥Esc) to free process
slots, then `pkill -9 watchman`.

## Open follow-ups
- Decide whether global Watchman is worth it vs. the recurring lockups (it
  backs jj "infinite undo" per CLAUDE.md).
- Consider a launchd agent so resource-climb-monitor is always running.
