//! Resolve a process id to its name + full command line. Used by the host
//! (`ghostty-host`) under the fork's pty-host: the host owns the PTY and the
//! foreground pid (via `tcgetpgrp`), so it resolves the human-facing name and
//! command line here and pushes the strings to the GUI (the GUI mirror cannot
//! resolve a host-process pid).
//!
//! macOS only for now: name via libproc `proc_name`, command line via
//! `sysctl(KERN_PROCARGS2)`. Other platforms return null (the core still
//! cross-compiles; the host is macOS-only in practice).

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

/// `sysctl` MIB constants. `std.c` exposes neither `CTL_KERN` nor
/// `KERN_PROCARGS2`, so define them here (stable values from `<sys/sysctl.h>`).
const CTL_KERN: c_int = 1;
const KERN_PROCARGS2: c_int = 49;

/// libproc `proc_name`: writes the process's (short) name into `buffer`,
/// returns the number of bytes written (<= 0 on failure). Links against
/// libSystem (already linked for the host/lib — no `linkSystemLibrary` needed).
extern "c" fn proc_name(pid: c_int, buffer: ?*anyopaque, buffersize: u32) c_int;

/// libproc `proc_listchildpids`: writes the pids of `ppid`'s DIRECT children into
/// `buffer`, returns the number of BYTES written (sizing call when buffer==null
/// returns the needed byte count); <= 0 on failure. libSystem (already linked).
extern "c" fn proc_listchildpids(ppid: c_int, buffer: ?*anyopaque, buffersize: c_int) c_int;

/// Resolved foreground process info. Both slices are owned by the allocator
/// passed to `resolve` (the caller frees them).
pub const ProcInfo = struct {
    name: []const u8,
    command: []const u8,
};

/// Launcher/shell/interpreter process names. The foreground pid (the
/// process-group LEADER from `tcgetpgrp`) is, for a WRAPPED launch, one of these
/// — and the program the user is actually interacting with is a descendant:
/// `bash …/claude-pool` spawns `claude`; `env`->`node`->`codex`. We descend
/// through launchers to the first NON-launcher process (the agent). basename-
/// compared and PURE, so it is unit-testable. Conservative: only well-known
/// runtimes/shells are listed, so we never descend past (or into) a real program.
pub fn isLauncher(name: []const u8) bool {
    const launchers = [_][]const u8{
        "sh",   "bash", "zsh",     "dash", "fish", "ksh", "tcsh",
        "env",  "login", "node",   "deno", "bun",
        "python", "python3", "ruby", "npx", "npm",
    };
    const base = std.fs.path.basename(name);
    for (launchers) |l| {
        if (std.mem.eql(u8, base, l)) return true;
    }
    return false;
}

/// Walk from `pid` DOWN through launcher processes to the first non-launcher
/// descendant — the program the user is interacting with. Descends only on an
/// UNAMBIGUOUS child (exactly one child, or a single non-launcher child when a
/// wrapper also spawned a transient shell); a genuine branch stops cleanly.
/// STOPS at the first non-launcher and never descends into ITS children, so it
/// never overshoots into helpers the agent itself spawns. Bounded depth. Returns
/// `pid` unchanged when it is already a real program (the common direct case).
/// Darwin-only (libproc); the non-Darwin `resolve` stub never calls it.
fn descendToProgram(pid: c_int) c_int {
    var cur = pid;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        var nbuf: [256]u8 = undefined;
        const n = proc_name(cur, &nbuf, nbuf.len);
        if (n <= 0) return cur; // can't name it -> resolve what we have
        if (!isLauncher(nbuf[0..@intCast(n)])) return cur; // first real program

        const next = singleChildForDescent(cur) orelse return cur;
        if (next <= 0 or next == cur) return cur; // paranoia: no self/invalid loop
        cur = next;
    }
    return cur;
}

/// The child pid to descend into, or null to stop. Exactly one child -> it;
/// multiple children -> the SOLE non-launcher child if there is exactly one (a
/// wrapper that also spawned a transient shell), else null (an ambiguous branch
/// we won't guess through). Zero children / failure -> null.
fn singleChildForDescent(pid: c_int) ?c_int {
    var buf: [256]c_int = undefined;
    const bufsize_bytes: c_int = @intCast(buf.len * @sizeOf(c_int));
    const got = proc_listchildpids(pid, &buf, bufsize_bytes);
    if (got <= 0) return null;
    const count = @min(@as(usize, @intCast(got)) / @sizeOf(c_int), buf.len);
    if (count == 0) return null;
    const kids = buf[0..count];
    if (count == 1) return kids[0];

    var pick: ?c_int = null;
    for (kids) |k| {
        if (k <= 0) continue;
        var nbuf: [256]u8 = undefined;
        const n = proc_name(k, &nbuf, nbuf.len);
        const launcher = n > 0 and isLauncher(nbuf[0..@intCast(n)]);
        if (!launcher) {
            if (pick != null) return null; // >1 non-launcher child: ambiguous
            pick = k;
        }
    }
    return pick;
}

/// Resolve `pid` -> `{name, command}`. Both slices are owned by `alloc` (caller
/// frees). Returns null on ANY failure (missing process, syscall error, corrupt
/// buffer) or on non-macOS. Never partially-allocs: on the failure path everything
/// taken from `alloc` is freed before returning null. NOTE: this returns an
/// OPTIONAL, not an error union, so `errdefer` would be dead code (it fires only
/// on an error return, not on `return null`). The contract is upheld instead by
/// (a) doing all the fallible sysctl work BEFORE taking any caller-owned string,
/// so the early-null paths have nothing to free, and (b) a manual free of
/// `command` on the final `name`-dupe failure path. Do NOT add an `errdefer` here.
pub fn resolve(alloc: Allocator, pid: u64) ?ProcInfo {
    // Non-macOS stub: the host is macOS-only in practice, and the GUI never calls
    // this (it consumes the pushed strings). Keeps the core cross-compiling. Note
    // we do NOT discard `alloc`/`pid` here — on a non-Darwin build everything
    // below is comptime-dead but still references them, so they count as used (the
    // idiomatic `if (comptime <off-target>) return null;` form, cf. kernel_info.zig).
    if (comptime !builtin.os.tag.isDarwin()) return null;

    const pid_root: c_int = std.math.cast(c_int, pid) orelse return null;
    // The foreground pid (`tcgetpgrp`) is the process-group LEADER, which for a
    // wrapped launch is a shell/interpreter (`bash …/claude-pool`, `env node …`);
    // descend through launchers to the actual program the user runs (e.g.
    // `claude`, `codex`) so the resolved name/command identify the agent, not the
    // wrapper. Returns pid_root unchanged for a direct (non-wrapped) program.
    const pid_c: c_int = descendToProgram(pid_root);

    // --- command line via sysctl(KERN_PROCARGS2) ---
    // Do ALL the fallible sysctl work FIRST, before allocating any caller-owned
    // string. `command` is the only allocation that survives the function, and
    // it is taken last, so the early-null paths (sysctl failures, OOM on the raw
    // buffer) have nothing caller-owned to free. `resolve` returns an optional
    // (not an error union), so `errdefer` would never fire on `return null` —
    // ordering the allocations is the only way to keep the never-partially-allocs
    // contract without a manual free at every early return.
    var mib = [_]c_int{ CTL_KERN, KERN_PROCARGS2, pid_c };

    // First call: size query (oldp == null).
    var size: usize = 0;
    if (std.c.sysctl(&mib, mib.len, null, &size, null, 0) != 0) return null;
    if (size == 0) return null;

    const raw = alloc.alloc(u8, size) catch return null;
    defer alloc.free(raw);

    // Second call: fill the buffer. `size` is updated to the actual length.
    if (std.c.sysctl(&mib, mib.len, raw.ptr, &size, null, 0) != 0) return null;

    const command = parseProcArgs2(alloc, raw[0..size]) catch return null;
    // parseProcArgs2 returns owned bytes (possibly empty) or an error; null is
    // not in its contract, so `command` is always a valid owned slice here.

    // --- name via proc_name ---
    // `<sys/proc_info.h>` sizes the name buffer at 2*MAXCOMLEN; 256 bytes is
    // ample. proc_name returns the byte count written (<= 0 => unavailable, in
    // which case we still report the command line and fall back to an empty name).
    // Allocated LAST: it is the only fallible step after `command` is taken, so
    // its OOM must free `command` explicitly. We do NOT use `errdefer` here:
    // `resolve` returns an optional, and `errdefer` fires only on an ERROR return,
    // never on `return null` — so an errdefer would be dead code and `command`
    // would leak. Hence the manual free on the name-dupe failure path.
    var nbuf: [256]u8 = undefined;
    const n = proc_name(pid_c, &nbuf, nbuf.len);
    const name: []const u8 = if (n > 0)
        alloc.dupe(u8, nbuf[0..@intCast(n)]) catch {
            alloc.free(command);
            return null;
        }
    else
        alloc.dupe(u8, "") catch {
            alloc.free(command);
            return null;
        };

    return .{ .name = name, .command = command };
}

/// Parse a `KERN_PROCARGS2` buffer into a single owned command-line string
/// (argv joined by single spaces). PURE + bounds-checked so it is unit-testable
/// against a synthetic buffer (the `sysctl` call itself is not unit-tested).
///
/// Layout (`<sys/sysctl.h>` KERN_PROCARGS2):
///   [ c_int argc ][ exec_path NUL ][ alignment NULs ][ argv[0] NUL ] ... [ argv[argc-1] NUL ] ...
/// (env strings follow argv; we stop after `argc` argv entries.)
///
/// Returns an owned (possibly empty) slice. Errors only on OOM; any malformed /
/// truncated buffer yields the args parsed so far (empty if none) rather than an
/// over-read — `resolve` is the place that maps "couldn't resolve" to a result.
fn parseProcArgs2(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    // argc is a leading native-endian c_int (4 bytes). Too short => empty.
    if (raw.len < @sizeOf(c_int)) return out.toOwnedSlice(alloc);
    const argc = std.mem.readInt(c_int, raw[0..@sizeOf(c_int)], builtin.cpu.arch.endian());
    if (argc <= 0) return out.toOwnedSlice(alloc);

    // Skip the exec path: a NUL-terminated string starting right after argc.
    var i: usize = @sizeOf(c_int);
    while (i < raw.len and raw[i] != 0) : (i += 1) {}
    // Skip the run of NULs (alignment padding) between exec path and argv[0].
    // EDGE: an empty argv[0] ("") is indistinguishable from this padding — its
    // leading NUL is consumed here, shifting the first real arg into argv[0]'s
    // slot. This is an inherent KERN_PROCARGS2 ambiguity (no length-prefix), is
    // astronomically rare (no normal exec produces an empty argv[0]), and the
    // result is only a coarse display string, so we accept it.
    while (i < raw.len and raw[i] == 0) : (i += 1) {}

    // Now read up to `argc` NUL-separated argv strings, joining with spaces.
    var parsed: c_int = 0;
    while (parsed < argc and i < raw.len) : (parsed += 1) {
        const start = i;
        while (i < raw.len and raw[i] != 0) : (i += 1) {}
        // A run with no terminator (truncated buffer) still contributes its
        // bytes; the loop ends at raw.len.
        const arg = raw[start..i];
        if (out.items.len != 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, arg);
        // Step past the NUL separator (if present).
        if (i < raw.len) i += 1;
    }

    return out.toOwnedSlice(alloc);
}

test "proc_info parseProcArgs2 parses argc + argv" {
    const alloc = std.testing.allocator;

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    // argc = 2
    var argc_bytes: [@sizeOf(c_int)]u8 = undefined;
    std.mem.writeInt(c_int, &argc_bytes, 2, builtin.cpu.arch.endian());
    try raw.appendSlice(alloc, &argc_bytes);
    // exec path + a NUL
    try raw.appendSlice(alloc, "/usr/bin/claude");
    try raw.append(alloc, 0);
    // a couple of alignment NULs
    try raw.append(alloc, 0);
    try raw.append(alloc, 0);
    // argv[0], argv[1]
    try raw.appendSlice(alloc, "claude");
    try raw.append(alloc, 0);
    try raw.appendSlice(alloc, "--resume");
    try raw.append(alloc, 0);
    // trailing env (ignored)
    try raw.appendSlice(alloc, "PATH=/bin");
    try raw.append(alloc, 0);

    const cmd = try parseProcArgs2(alloc, raw.items);
    defer alloc.free(cmd);
    try std.testing.expectEqualStrings("claude --resume", cmd);
}

test "proc_info parseProcArgs2 truncated argv returns partial, no OOB" {
    const alloc = std.testing.allocator;

    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(alloc);
    // argc claims 3 but only 1 argv is present + the last is unterminated.
    var argc_bytes: [@sizeOf(c_int)]u8 = undefined;
    std.mem.writeInt(c_int, &argc_bytes, 3, builtin.cpu.arch.endian());
    try raw.appendSlice(alloc, &argc_bytes);
    try raw.appendSlice(alloc, "/bin/sh");
    try raw.append(alloc, 0);
    // argv[0] terminated, argv[1] NOT terminated (buffer ends mid-string).
    try raw.appendSlice(alloc, "sh");
    try raw.append(alloc, 0);
    try raw.appendSlice(alloc, "-c"); // no trailing NUL

    const cmd = try parseProcArgs2(alloc, raw.items);
    defer alloc.free(cmd);
    // Both reachable args contribute; no panic / OOB read past raw.len.
    try std.testing.expectEqualStrings("sh -c", cmd);
}

test "proc_info parseProcArgs2 argc=0 returns empty" {
    const alloc = std.testing.allocator;

    var argc_bytes: [@sizeOf(c_int)]u8 = undefined;
    std.mem.writeInt(c_int, &argc_bytes, 0, builtin.cpu.arch.endian());

    const cmd = try parseProcArgs2(alloc, &argc_bytes);
    defer alloc.free(cmd);
    try std.testing.expectEqual(@as(usize, 0), cmd.len);
}

test "proc_info parseProcArgs2 buffer shorter than argc returns empty" {
    const alloc = std.testing.allocator;
    const tiny = [_]u8{ 1, 2 }; // < sizeof(c_int)
    const cmd = try parseProcArgs2(alloc, &tiny);
    defer alloc.free(cmd);
    try std.testing.expectEqual(@as(usize, 0), cmd.len);
}

test "proc_info isLauncher recognizes shells/interpreters, not real programs" {
    // Shells + interpreters/wrappers are launchers (we descend through them).
    try std.testing.expect(isLauncher("bash"));
    try std.testing.expect(isLauncher("zsh"));
    try std.testing.expect(isLauncher("sh"));
    try std.testing.expect(isLauncher("env"));
    try std.testing.expect(isLauncher("node"));
    try std.testing.expect(isLauncher("python3"));
    // Path-qualified names are basenamed.
    try std.testing.expect(isLauncher("/bin/bash"));
    try std.testing.expect(isLauncher("/usr/bin/env"));
    // The agents themselves are NOT launchers -> descent STOPS at them.
    try std.testing.expect(!isLauncher("claude"));
    try std.testing.expect(!isLauncher("codex"));
    try std.testing.expect(!isLauncher("/Users/x/.local/bin/claude"));
    // A wrapper SCRIPT named claude-pool is not itself a launcher binary (it is
    // `bash` that runs it); the basename must not partial-match a launcher.
    try std.testing.expect(!isLauncher("claude-pool"));
    try std.testing.expect(!isLauncher("vim"));
    try std.testing.expect(!isLauncher(""));
}
