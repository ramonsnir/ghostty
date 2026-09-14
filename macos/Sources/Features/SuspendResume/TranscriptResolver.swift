import Foundation
import Darwin

/// (ramon fork / suspend-resume) Recover a Claude split's `--resume` session id (+ cwd) from
/// Claude Code's ON-DISK transcripts, for when the ephemeral hook capture is unavailable — e.g.
/// a long-idle split that hasn't fired a hook since the GUI launched (idle sessions predate a
/// relaunch). Claude writes each session to `~/.claude/projects/<cwd-encoded>/<session_id>.jsonl`,
/// so: find the `claude` process under the split's foreground pid, read its cwd, and take the
/// newest transcript in that project dir. Pure cores are injectable for tests; the libproc /
/// filesystem glue is thin. See SUSPEND-RESUME-DESIGN.md.
enum TranscriptResolver {

    // MARK: - Pure cores (unit-tested)

    /// Claude Code's project-dir encoding of a cwd: every NON-alphanumeric ASCII char → '-'
    /// (existing '-' is preserved because it isn't alphanumeric and maps to '-'). Verified
    /// against real dirs: `/Users/ramon/git/NoetiveOS` → `-Users-ramon-git-NoetiveOS`;
    /// `/Users/ramon/.config/x` → `-Users-ramon--config-x`; `Ghostty (ramon).app` →
    /// `Ghostty--ramon--app`.
    static func encodeProjectDir(_ cwd: String) -> String {
        String(cwd.map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
    }

    /// A Claude session id is a uuid — conservative shape check (hex + dashes, 32–40 chars).
    static func isSessionId(_ s: String) -> Bool {
        guard s.count >= 32, s.count <= 40, s.contains("-") else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        return s.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The session id of the NEWEST `.jsonl` among a project dir's entries (the active session's
    /// transcript is the most recently written). nil when there's no valid transcript.
    static func newestSessionId(entries: [(name: String, mtime: Double)]) -> String? {
        for e in entries.filter({ $0.name.hasSuffix(".jsonl") }).sorted(by: { $0.mtime > $1.mtime }) {
            let id = String(e.name.dropLast(6)) // ".jsonl"
            if isSessionId(id) { return id }
        }
        return nil
    }

    /// Find the `claude` process pid under `root` (subtree walk via `childrenMap`), matched by
    /// exe basename. Injectable `exePathOf` for tests; bounded depth + a visited guard.
    static func claudePid(under root: pid_t, childrenMap: [pid_t: [pid_t]],
                          exePathOf: (pid_t) -> String, maxDepth: Int = 6) -> pid_t? {
        var stack: [(pid: pid_t, depth: Int)] = [(root, 0)]
        var visited = Set<pid_t>()
        while let (pid, depth) = stack.popLast() {
            guard visited.insert(pid).inserted else { continue }
            if (exePathOf(pid) as NSString).lastPathComponent == "claude" { return pid }
            if depth < maxDepth { for c in childrenMap[pid] ?? [] { stack.append((c, depth + 1)) } }
        }
        return nil
    }

    // MARK: - libproc / filesystem glue (impure)

    /// The recovered `(sessionId, cwd)` for a split given its foreground pid, or nil (no claude
    /// under it, or no transcript). Reuses the cached process-table children map.
    static func recover(foregroundPid: pid_t,
                        home: String = NSHomeDirectory()) -> (sessionId: String, cwd: String)? {
        let cmap = MCPAgentState.cachedChildrenMap()
        guard let claude = claudePid(under: foregroundPid, childrenMap: cmap, exePathOf: exePath),
              let cwd = cwdOf(claude) else { return nil }
        let dir = "\(home)/.claude/projects/\(encodeProjectDir(cwd))"
        guard let sid = newestSessionId(entries: directoryEntries(dir)) else { return nil }
        return (sid, cwd)
    }

    private static func exePath(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        return proc_pidpath(pid, &buf, UInt32(MAXPATHLEN)) > 0 ? String(cString: buf) : ""
    }

    private static func cwdOf(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let sz = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, sz) == sz else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            return String(cString: base.assumingMemoryBound(to: CChar.self))
        }
        return path.isEmpty ? nil : path
    }

    private static func directoryEntries(_ dir: String) -> [(name: String, mtime: Double)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return names.map { name in
            let m = ((try? fm.attributesOfItem(atPath: "\(dir)/\(name)"))?[.modificationDate]
                as? Date)?.timeIntervalSince1970 ?? 0
            return (name, m)
        }
    }
}
