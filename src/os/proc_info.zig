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
    // Linux arm: the fork's `ghostty-host` also runs on Linux cloud boxes, where
    // the foreground pid already resolves (via `tcgetpgrp`) but the name/command
    // must come from `/proc`. This branch returns FIRST on a Linux target, so the
    // Darwin sysctl/libproc body below is comptime-dead there (never analyzed) —
    // exactly as the `if (comptime !isDarwin)` guard makes it dead on every other
    // target. See `resolveLinux`.
    if (comptime builtin.os.tag == .linux) return resolveLinux(alloc, pid);

    // Non-macOS / non-Linux stub: keeps the core cross-compiling. Note we do NOT
    // discard `alloc`/`pid` here — on such a build everything below is comptime-
    // dead but still references them, so they count as used (the idiomatic
    // `if (comptime <off-target>) return null;` form, cf. kernel_info.zig).
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

// =============================================================================
// Linux `/proc` arm
//
// The fork's `ghostty-host` also runs on Linux cloud boxes. `foreground_pid`
// already resolves on Linux (`pty.zig` `tcgetpgrp`), so ONLY the name + command
// need a `/proc` reader here — this fills the already-negotiated (minor-3)
// process_info frame; NO protocol change. All the `/proc` I/O functions are only
// referenced from `resolveLinux` (and the `.linux`-gated test), so on a non-Linux
// build they are unreferenced and never analyzed. The pure `parseProcCmdline`
// parser and the pure decision helpers (`parsePpidFromStat`, `pickDescendChild`)
// are target-agnostic and unit-tested.
// =============================================================================

/// A direct child of some pid, plus whether its (comm) name is a launcher.
/// Used by the pure `pickDescendChild` selection.
const DescendChild = struct { pid: i32, launcher: bool };

/// Resolve `pid` -> `{name, command}` on Linux by reading `/proc`. Contract
/// mirrors `resolve` (Darwin): both slices owned by `alloc`, null on ANY failure,
/// never partially-allocs (all fallible reads happen before/around the two dupes,
/// and the name dupe frees `command` on its own OOM). Descends through launcher
/// wrappers (`bash …/claude-pool`, `env node …`) to the real program first.
fn resolveLinux(alloc: Allocator, pid: u64) ?ProcInfo {
    const pid_root: i32 = std.math.cast(i32, pid) orelse return null;
    var src: LinuxProcSource = .{};
    const pid_c = descendToProgramImpl(LinuxProcSource, &src, pid_root);

    // command via /proc/<pid>/cmdline (NUL-separated argv). Errors only on OOM;
    // any read failure yields an owned empty string (coarse display fallback).
    const command = readCmdlineLinux(alloc, pid_c) catch return null;

    // name via /proc/<pid>/comm (falls back to an empty owned string).
    var name_buf: [256]u8 = undefined;
    const name: []const u8 = if (readCommLinux(pid_c, &name_buf)) |s|
        alloc.dupe(u8, s) catch {
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

/// Parse a `/proc/<pid>/cmdline` buffer into a single owned command-line string
/// (argv joined by single spaces). `/proc/<pid>/cmdline` is the process's argv
/// with each argument NUL-terminated and NO leading argc / exec-path header — the
/// simpler sibling of Darwin's `KERN_PROCARGS2`. PURE + bounds-safe so it is
/// unit-testable on ANY target against a synthetic buffer. Empty runs (the
/// trailing NUL, or a zombie's empty cmdline) contribute nothing. Errors only on
/// OOM; returns an owned (possibly empty) slice otherwise.
fn parseProcCmdline(alloc: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        if (out.items.len != 0) try out.append(alloc, ' ');
        try out.appendSlice(alloc, arg);
    }

    return out.toOwnedSlice(alloc);
}

/// Read `/proc/<pid>/cmdline` and parse it. Owned (possibly empty) slice; errors
/// only on OOM (a missing/unreadable file yields an owned empty string).
fn readCmdlineLinux(alloc: Allocator, pid: i32) Allocator.Error![]u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var data_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/cmdline", .{pid}) catch
        return parseProcCmdline(alloc, "");
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch
        return parseProcCmdline(alloc, "");
    defer file.close();
    const n = file.readAll(&data_buf) catch return parseProcCmdline(alloc, "");
    return parseProcCmdline(alloc, data_buf[0..n]);
}

/// Read `/proc/<pid>/comm` into `buf`, returning the trimmed (short) process
/// name or null on failure. The slice aliases `buf` (valid until the next read).
fn readCommLinux(pid: i32, buf: []u8) ?[]const u8 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/proc/{d}/comm", .{pid}) catch return null;
    const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch return null;
    defer file.close();
    const n = file.readAll(buf) catch return null;
    if (n == 0) return null;
    return std.mem.trimRight(u8, buf[0..n], "\n");
}

/// Generic descend loop shared in shape with Darwin's `descendToProgram`, but
/// factored over a `Src` so the Linux port is unit-testable against a fixture
/// process table. Walks DOWN through launcher processes to the first non-launcher
/// descendant (the program the user runs). `Src` must provide
/// `name(pid) ?[]const u8` (valid until the next call) and `singleChild(pid) ?i32`.
/// Bounded depth; stops at an ambiguous branch, an unnameable pid, or a real
/// program (returns `pid` unchanged for a direct, non-wrapped program).
fn descendToProgramImpl(comptime Src: type, src: *Src, pid: i32) i32 {
    var cur = pid;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        const name = src.name(cur) orelse return cur; // can't name -> resolve this
        if (!isLauncher(name)) return cur; // first real program
        const next = src.singleChild(cur) orelse return cur;
        if (next <= 0 or next == cur) return cur; // paranoia: no self/invalid loop
        cur = next;
    }
    return cur;
}

/// The concrete Linux `descendToProgramImpl` source: name via `/proc/<pid>/comm`,
/// child via `singleChildForDescentLinux`.
const LinuxProcSource = struct {
    name_buf: [256]u8 = undefined,

    fn name(self: *LinuxProcSource, pid: i32) ?[]const u8 {
        return readCommLinux(pid, &self.name_buf);
    }
    fn singleChild(self: *LinuxProcSource, pid: i32) ?i32 {
        _ = self;
        return singleChildForDescentLinux(pid);
    }
};

/// Linux equivalent of `singleChildForDescent`: collect `pid`'s direct children
/// (from `/proc/<pid>/task/<pid>/children`, or a `/proc/*/stat` PPID scan
/// fallback) and apply the pure `pickDescendChild` rule.
fn singleChildForDescentLinux(pid: i32) ?i32 {
    var children: [64]DescendChild = undefined;
    const n = collectChildrenLinux(pid, &children);
    if (n == 0) return null;
    return pickDescendChild(children[0..n]);
}

/// Pure: choose the child pid to descend into. Mirrors the Darwin rule — exactly
/// one child -> it; multiple children -> the SOLE non-launcher child if unique
/// (a wrapper that also spawned a transient shell), else null (ambiguous branch);
/// zero -> null. Target-agnostic + pure so it is unit-testable.
fn pickDescendChild(children: []const DescendChild) ?i32 {
    if (children.len == 0) return null;
    if (children.len == 1) return children[0].pid;

    var pick: ?i32 = null;
    for (children) |c| {
        if (c.pid <= 0) continue;
        if (!c.launcher) {
            if (pick != null) return null; // >1 non-launcher child: ambiguous
            pick = c.pid;
        }
    }
    return pick;
}

/// Fill `out` with `pid`'s direct children (+ their launcher flags), returning
/// the count. Prefers `/proc/<pid>/task/<pid>/children`; on empty/failure falls
/// back to scanning `/proc/*/stat` for entries whose PPID == `pid`.
fn collectChildrenLinux(pid: i32, out: []DescendChild) usize {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var data_buf: [4096]u8 = undefined;

    // Preferred: the kernel's own children list (space-separated child pids).
    if (std.fmt.bufPrint(&path_buf, "/proc/{d}/task/{d}/children", .{ pid, pid })) |path| {
        if (std.fs.openFileAbsolute(path, .{ .mode = .read_only })) |file| {
            const n = blk: {
                defer file.close();
                break :blk file.readAll(&data_buf) catch 0;
            };
            if (n > 0) {
                var count: usize = 0;
                var it = std.mem.tokenizeAny(u8, data_buf[0..n], " \n\t");
                while (it.next()) |tok| {
                    if (count >= out.len) break;
                    const cpid = std.fmt.parseInt(i32, tok, 10) catch continue;
                    out[count] = .{ .pid = cpid, .launcher = childIsLauncherLinux(cpid) };
                    count += 1;
                }
                if (count > 0) return count;
            }
        } else |_| {}
    } else |_| {}

    // Fallback: scan /proc/*/stat for PPID == pid.
    return scanChildrenByPpidLinux(pid, out);
}

/// Scan `/proc/*/stat` for processes whose parent pid is `ppid`, filling `out`.
/// The `/proc/<pid>/task/<pid>/children` file is not always available (kernel
/// config), so this is the portable fallback.
fn scanChildrenByPpidLinux(ppid: i32, out: []DescendChild) usize {
    var dir = std.fs.openDirAbsolute("/proc", .{ .iterate = true }) catch return 0;
    defer dir.close();

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var data_buf: [4096]u8 = undefined;
    var count: usize = 0;

    var it = dir.iterate();
    while (it.next() catch return count) |entry| {
        if (count >= out.len) break;
        // Only numeric pid dirs.
        const cpid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        if (cpid == ppid) continue;

        const path = std.fmt.bufPrint(&path_buf, "/proc/{s}/stat", .{entry.name}) catch continue;
        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_only }) catch continue;
        const n = blk: {
            defer file.close();
            break :blk file.readAll(&data_buf) catch 0;
        };
        if (n == 0) continue;

        const parsed_ppid = parsePpidFromStat(data_buf[0..n]) orelse continue;
        if (parsed_ppid != ppid) continue;
        out[count] = .{ .pid = cpid, .launcher = childIsLauncherLinux(cpid) };
        count += 1;
    }
    return count;
}

/// Whether child `pid`'s `/proc/<pid>/comm` name is a launcher. Failure ⇒ treated
/// as NON-launcher (conservative: we won't descend blindly through an unnameable
/// child, but `pickDescendChild` may still select it if it is the sole one).
fn childIsLauncherLinux(pid: i32) bool {
    var buf: [256]u8 = undefined;
    const name = readCommLinux(pid, &buf) orelse return false;
    return isLauncher(name);
}

/// Pure: parse the parent pid (PPID) out of a `/proc/<pid>/stat` line. The comm
/// field (2nd) is wrapped in parens and MAY itself contain spaces AND parens, so
/// the reliable anchor is the LAST ')': after it come `state ppid …`
/// (space-separated). Returns null on any malformed input. Target-agnostic + pure
/// so it is unit-testable.
fn parsePpidFromStat(raw: []const u8) ?i32 {
    const close = std.mem.lastIndexOfScalar(u8, raw, ')') orelse return null;
    if (close + 1 >= raw.len) return null;
    var it = std.mem.tokenizeScalar(u8, raw[close + 1 ..], ' ');
    _ = it.next() orelse return null; // state
    const ppid_tok = it.next() orelse return null; // ppid
    return std.fmt.parseInt(i32, ppid_tok, 10) catch null;
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

test "proc_info parseProcCmdline joins NUL-separated argv" {
    // Target-agnostic: the /proc/<pid>/cmdline layout is argv with each argument
    // NUL-terminated (no argc/exec-path header). Runs on ANY target.
    const alloc = std.testing.allocator;
    {
        // Typical: two args + trailing NUL.
        const cmd = try parseProcCmdline(alloc, "claude\x00--resume\x00");
        defer alloc.free(cmd);
        try std.testing.expectEqualStrings("claude --resume", cmd);
    }
    {
        // Empty buffer -> empty owned string.
        const cmd = try parseProcCmdline(alloc, "");
        defer alloc.free(cmd);
        try std.testing.expectEqual(@as(usize, 0), cmd.len);
    }
    {
        // Only NULs -> empty (all runs empty).
        const cmd = try parseProcCmdline(alloc, "\x00\x00\x00");
        defer alloc.free(cmd);
        try std.testing.expectEqual(@as(usize, 0), cmd.len);
    }
    {
        // Unterminated final arg still contributes; no OOB.
        const cmd = try parseProcCmdline(alloc, "bash\x00-lc");
        defer alloc.free(cmd);
        try std.testing.expectEqualStrings("bash -lc", cmd);
    }
    {
        // Embedded empty arg between two reals is dropped (coarse display).
        const cmd = try parseProcCmdline(alloc, "a\x00\x00b\x00");
        defer alloc.free(cmd);
        try std.testing.expectEqualStrings("a b", cmd);
    }
}

test "proc_info descendToProgram /proc PPID fixture" {
    // Comptime-gated to Linux: the /proc descend + its helpers are only compiled
    // on a Linux target, so the whole body compiles-OUT on macOS but is real on
    // Linux (the human runs a Linux cross-compile to fully type-check the arm).
    if (comptime builtin.os.tag != .linux) return error.SkipZigTest;

    // --- parsePpidFromStat: comm may contain spaces AND parens; anchor last ')'.
    try std.testing.expectEqual(
        @as(?i32, 1000),
        parsePpidFromStat("1234 (claude pool) S 1000 1234 1000 34816"),
    );
    try std.testing.expectEqual(@as(?i32, 0), parsePpidFromStat("1 (systemd) S 0 1 1"));
    // A comm with an embedded ')' — the LAST ')' is the anchor.
    try std.testing.expectEqual(
        @as(?i32, 42),
        parsePpidFromStat("77 (weird)name) R 42 77"),
    );
    // Malformed -> null.
    try std.testing.expectEqual(@as(?i32, null), parsePpidFromStat("garbage no paren"));
    try std.testing.expectEqual(@as(?i32, null), parsePpidFromStat(""));

    // --- pickDescendChild: single -> it; multiple -> sole non-launcher; else null.
    try std.testing.expectEqual(
        @as(?i32, 42),
        pickDescendChild(&.{.{ .pid = 42, .launcher = true }}),
    );
    try std.testing.expectEqual(@as(?i32, 7), pickDescendChild(&.{
        .{ .pid = 5, .launcher = true },
        .{ .pid = 7, .launcher = false },
    }));
    try std.testing.expectEqual(@as(?i32, null), pickDescendChild(&.{
        .{ .pid = 7, .launcher = false },
        .{ .pid = 9, .launcher = false },
    }));
    try std.testing.expectEqual(@as(?i32, null), pickDescendChild(&.{}));

    // --- Fixture descend: bash(100) -> claude-pool==bash(200) -> claude(300).
    // The wrapper chain is all launchers; descent stops at the first non-launcher.
    const Fixture = struct {
        name_buf: [256]u8 = undefined,
        fn name(self: *@This(), pid: i32) ?[]const u8 {
            const s: []const u8 = switch (pid) {
                100 => "bash",
                200 => "bash", // the claude-pool wrapper runs as bash
                300 => "claude",
                else => return null,
            };
            @memcpy(self.name_buf[0..s.len], s);
            return self.name_buf[0..s.len];
        }
        fn singleChild(self: *@This(), pid: i32) ?i32 {
            _ = self;
            return switch (pid) {
                100 => 200,
                200 => 300,
                else => null,
            };
        }
    };
    var fx: Fixture = .{};
    // From the wrapper leader, descent lands on the real agent.
    try std.testing.expectEqual(@as(i32, 300), descendToProgramImpl(Fixture, &fx, 100));
    // Already a real program: returned unchanged (never overshoots into its kids).
    try std.testing.expectEqual(@as(i32, 300), descendToProgramImpl(Fixture, &fx, 300));
    // Unnameable pid: resolve what we have.
    try std.testing.expectEqual(@as(i32, 999), descendToProgramImpl(Fixture, &fx, 999));
}
