import Foundation
import AppKit
import OSLog

/// (ramon fork) One-shot, SAFE installer for the fork's Claude Code agent-state
/// hooks, so a colleague never has to hand-edit `~/.claude/settings.json`.
///
/// "Install" is two steps:
///   1. Copy the hook script to
///      `~/.config/ghostty-ramon/claude-hooks/ghostty-agent-state.sh`
///      (mkdir -p; chmod 0755; atomic `Data.write` so the bundle's quarantine
///      xattr never propagates — same pattern as `ForkSetup.installShimIfNeeded`).
///   2. Merge SIX hook events into `~/.claude/settings.json` under `"hooks"`,
///      each running that script with a state arg (working/working/waiting/idle/
///      working/idle for UserPromptSubmit / PreToolUse / Notification / Stop /
///      SessionStart / SessionEnd).
///
/// The merge is the delicate part: it edits the user's Claude Code config, so it
/// MUST be safe — back up first, merge IDEMPOTENTLY, preserve every existing
/// entry, and ABORT (never overwrite) a malformed settings file. The pure merge/
/// detect helpers are unit-tested.
///
/// The hook script itself is EMBEDDED below as `hookScript` (a verbatim copy of
/// `example/claude-hooks/ghostty-agent-state.sh`, the repo's source of truth) so
/// the installer is self-contained and works in BOTH a plain ReleaseLocal Xcode
/// build (which does NOT bundle `Contents/Resources/claude-hooks/`) AND the DMG.
/// ⚠️ Keep `hookScript` byte-in-sync with that file whenever it changes.
enum AgentHooksInstaller {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.mitchellh.ghostty",
        category: "agent-hooks")

    // MARK: - Paths

    /// The six Claude Code hook events we wire, in a stable order, each paired
    /// with the agent state passed to the script. Source of truth mirrors
    /// `example/claude-hooks/settings-hooks.json`.
    ///
    /// PreToolUse additionally carries a `"*"` matcher (match all tools); the
    /// others carry no matcher (they are not tool-scoped).
    struct HookEvent {
        let name: String
        let state: String
        let matcher: String?
    }

    static let hookEvents: [HookEvent] = [
        .init(name: "UserPromptSubmit", state: "working", matcher: nil),
        .init(name: "PreToolUse", state: "working", matcher: "*"),
        .init(name: "Notification", state: "waiting", matcher: nil),
        .init(name: "Stop", state: "idle", matcher: nil),
        .init(name: "SessionStart", state: "working", matcher: nil),
        .init(name: "SessionEnd", state: "idle", matcher: nil),
    ]

    /// The marker substring used to recognize OUR hook command (for idempotent
    /// detection) — present in every command we write.
    static let scriptMarker = "ghostty-agent-state.sh"

    /// The installed hook-script path, as referenced by the settings commands.
    /// Uses a literal `~` so the written JSON matches `settings-hooks.json` and
    /// is portable across machines (Claude Code expands `~`).
    static let scriptCommandPrefix =
        "~/.config/ghostty-ramon/claude-hooks/ghostty-agent-state.sh"

    static func scriptDir(home: String) -> String {
        "\(home)/.config/ghostty-ramon/claude-hooks"
    }

    static func scriptPath(home: String) -> String {
        "\(scriptDir(home: home))/ghostty-agent-state.sh"
    }

    static func settingsPath(home: String) -> String {
        "\(home)/.claude/settings.json"
    }

    // MARK: - Result types

    /// Outcome of a full `install()`.
    struct InstallResult {
        /// Whether the script file was (re)written.
        var scriptWritten: Bool
        /// The merge outcome for settings.json.
        var merge: MergeResult
        /// Where the prior settings.json was backed up (nil if there was none).
        var backupPath: String?
    }

    /// Pure outcome of merging our hook events into a settings object.
    struct MergeResult: Equatable {
        /// True when settings.json did not exist (we created it fresh).
        var created: Bool
        /// Events whose entry we appended (were not already installed).
        var added: [String]
        /// Events that were already installed (we left them untouched).
        var skipped: [String]

        var changed: Bool { created || !added.isEmpty }
    }

    enum InstallError: Error, CustomStringConvertible {
        /// settings.json exists but is not valid JSON — we refuse to overwrite it.
        case malformedSettings(path: String)
        /// settings.json exists but its top-level value is not a JSON object.
        case settingsNotObject(path: String)
        /// Could not serialize the merged settings to JSON.
        case serializationFailed

        var description: String {
            switch self {
            case .malformedSettings(let path):
                return "\(path) is not valid JSON; refusing to overwrite it. " +
                    "Fix or remove it, then try again."
            case .settingsNotObject(let path):
                return "\(path) does not contain a JSON object at the top level; " +
                    "refusing to modify it."
            case .serializationFailed:
                return "Failed to serialize the merged Claude settings."
            }
        }
    }

    // MARK: - Pure: detection

    /// True iff `settings` already contains AT LEAST ONE of our hook commands in
    /// ANY of the six events. Used both for idempotency and to decide whether to
    /// auto-offer the install on launch. Tolerant of arbitrary user structure:
    /// any string value anywhere under `hooks` that contains our script marker
    /// counts as installed for that event.
    static func hooksInstalled(settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any] else { return false }
        for event in hookEvents {
            if let arr = hooks[event.name] as? [Any], arrayContainsOurHook(arr) {
                return true
            }
        }
        return false
    }

    /// True iff the given event's entry array already contains one of OUR hook
    /// commands (a hook whose `"command"` string contains the script marker).
    static func arrayContainsOurHook(_ entries: [Any]) -> Bool {
        for entry in entries {
            guard let dict = entry as? [String: Any] else { continue }
            guard let inner = dict["hooks"] as? [Any] else { continue }
            for h in inner {
                if let hd = h as? [String: Any],
                   let cmd = hd["command"] as? String,
                   cmd.contains(scriptMarker) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Pure: the entry we append

    /// Build the settings entry object for one event (mirrors
    /// `settings-hooks.json`): `{ ["matcher": "*"], "hooks": [ { "type":
    /// "command", "command": "<script> <state>" } ] }`.
    static func entry(for event: HookEvent) -> [String: Any] {
        var obj: [String: Any] = [
            "hooks": [
                [
                    "type": "command",
                    "command": "\(scriptCommandPrefix) \(event.state)",
                ] as [String: Any],
            ] as [Any],
        ]
        if let matcher = event.matcher {
            obj["matcher"] = matcher
        }
        return obj
    }

    // MARK: - Pure: the merge

    /// Merge our six hook events into `settings` (a parsed top-level object),
    /// returning the NEW settings plus a `MergeResult`. PURE — no I/O.
    ///
    /// Semantics (safety-critical):
    ///   * Every other top-level key is preserved untouched.
    ///   * `hooks` is created if absent (preserving an existing one).
    ///   * For each event: if ANY existing entry already carries our hook command
    ///     (`arrayContainsOurHook`), the event is SKIPPED (idempotent). Otherwise
    ///     our entry is APPENDED, preserving every existing entry.
    static func mergeHooks(
        into settings: [String: Any],
        wasCreated: Bool = false
    ) -> (settings: [String: Any], result: MergeResult) {
        var out = settings
        var hooks = (out["hooks"] as? [String: Any]) ?? [:]
        var added: [String] = []
        var skipped: [String] = []

        for event in hookEvents {
            var arr = (hooks[event.name] as? [Any]) ?? []
            if arrayContainsOurHook(arr) {
                skipped.append(event.name)
                continue
            }
            arr.append(entry(for: event))
            hooks[event.name] = arr
            added.append(event.name)
        }

        out["hooks"] = hooks
        return (out, MergeResult(created: wasCreated, added: added, skipped: skipped))
    }

    // MARK: - Pure: auto-offer decision

    /// Whether the launch-time one-time prompt should be shown: a queue/manager
    /// feature is enabled, the hooks are NOT installed, and we have not asked
    /// before. Pure (the caller supplies the three bits).
    static func shouldAutoOfferHooks(
        featureEnabled: Bool,
        installed: Bool,
        alreadyAsked: Bool
    ) -> Bool {
        featureEnabled && !installed && !alreadyAsked
    }

    // MARK: - Impure: parse settings from disk

    /// Read + parse settings.json. Returns:
    ///   * `nil` if the file is absent (caller starts from `{}` / created=true).
    ///   * throws `.malformedSettings` if present but not valid JSON.
    ///   * throws `.settingsNotObject` if valid JSON but not a top-level object.
    static func readSettings(
        path: String, fileManager: FileManager = .default
    ) throws -> [String: Any]? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        guard let data = fileManager.contents(atPath: path) else {
            // Unreadable empty/absent contents — treat as malformed rather than
            // silently clobber.
            throw InstallError.malformedSettings(path: path)
        }
        // An empty file is not valid JSON; treat as malformed (do not overwrite).
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw InstallError.malformedSettings(path: path)
        }
        guard let dict = obj as? [String: Any] else {
            throw InstallError.settingsNotObject(path: path)
        }
        return dict
    }

    // MARK: - Impure: backup

    /// Pick a backup path that does not clobber an existing backup. First choice
    /// is `<path>.ghostty-backup`; if that exists, append a timestamp.
    static func backupPath(
        for path: String, fileManager: FileManager = .default,
        now: Date = Date()
    ) -> String {
        let primary = "\(path).ghostty-backup"
        if !fileManager.fileExists(atPath: primary) { return primary }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyyMMdd-HHmmss"
        return "\(path).ghostty-backup-\(fmt.string(from: now))"
    }

    // MARK: - Impure: full install

    /// Perform the full install (copy script + merge settings, with backup).
    /// Safe + idempotent. Returns a result describing what happened, or throws on
    /// a malformed settings file (we never overwrite one).
    ///
    /// Run OFF the main thread (it touches the filesystem); the caller presents
    /// the result on main.
    static func install(
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) throws -> InstallResult {
        // 1) Write the script.
        let scriptWritten = try writeScript(home: home, fileManager: fileManager)

        // 2) Merge settings.json (with backup).
        let settingsFile = settingsPath(home: home)
        let existing = try readSettings(path: settingsFile, fileManager: fileManager)

        var backup: String? = nil
        let base: [String: Any]
        let wasCreated: Bool
        if let existing {
            base = existing
            wasCreated = false
        } else {
            base = [:]
            wasCreated = true
        }

        let (merged, result) = mergeHooks(into: base, wasCreated: wasCreated)

        // Only write (and back up) if something actually changed.
        if result.changed {
            // Back up the prior file before overwriting (only if it existed).
            if !wasCreated, fileManager.fileExists(atPath: settingsFile) {
                let bp = backupPath(for: settingsFile, fileManager: fileManager)
                if let data = fileManager.contents(atPath: settingsFile) {
                    try data.write(to: URL(fileURLWithPath: bp), options: .atomic)
                    backup = bp
                }
            }

            // Ensure the ~/.claude dir exists.
            let claudeDir = URL(fileURLWithPath: settingsFile)
                .deletingLastPathComponent().path
            try fileManager.createDirectory(
                atPath: claudeDir, withIntermediateDirectories: true)

            guard let outData = try? JSONSerialization.data(
                withJSONObject: merged,
                options: [.prettyPrinted, .sortedKeys])
            else {
                throw InstallError.serializationFailed
            }
            try outData.write(
                to: URL(fileURLWithPath: settingsFile), options: .atomic)
        }

        return InstallResult(
            scriptWritten: scriptWritten, merge: result, backupPath: backup)
    }

    /// Write (or refresh) the hook script. Atomic `Data.write` (so no quarantine
    /// xattr propagates) + chmod 0755 + mkdir -p. Returns true if it wrote.
    @discardableResult
    static func writeScript(
        home: String, fileManager: FileManager = .default
    ) throws -> Bool {
        let dir = scriptDir(home: home)
        let target = scriptPath(home: home)
        try fileManager.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        // The embedded raw multiline literal drops the trailing newline before
        // the closing delimiter, so re-add exactly one so the on-disk file is
        // byte-identical to example/claude-hooks/ghostty-agent-state.sh.
        let contents = hookScript.hasSuffix("\n") ? hookScript : hookScript + "\n"
        let data = Data(contents.utf8)
        try data.write(to: URL(fileURLWithPath: target), options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: target)
        return true
    }

    // MARK: - Embedded hook script (verbatim source of truth)
    //
    // ⚠️ KEEP BYTE-IN-SYNC with example/claude-hooks/ghostty-agent-state.sh —
    // that file is the source of truth; this is an embedded verbatim copy so the
    // installer is self-contained (no bundle dependency; works in ReleaseLocal).
    // The raw multiline literal (#"""…"""#) preserves backslashes and quotes;
    // Swift drops the leading + trailing newline, so `writeScript` re-adds the
    // single trailing newline.

    static let hookScript = #"""
#!/usr/bin/env bash
# (ramon fork / Agent hooks) Claude Code hook -> Ghostty MCP `/agent-state`.
#
# Invoked by Claude Code's hook machinery (see settings-hooks.json) with the
# agent state as the first CLI arg:
#
#     ghostty-agent-state.sh <working|waiting|idle>
#
# It derives the controlling tty of the terminal Claude Code is running in,
# best-effort extracts a tool/prompt/message hint from the hook JSON on stdin,
# and fires a single fire-and-forget POST to the in-GUI MCP server at
# http://127.0.0.1:<port>/agent-state. The Ghostty MCP handler resolves the tty
# to the matching terminal surface (via the host-pushed foreground pid) and
# drives the Agent Dashboard tile's per-tile agent state + a Web Push on
# "waiting". GUI + hooks only — there is no host change.
#
# Design: the hook MUST NEVER block or fail the agent. Everything is best-effort:
# a missing server, missing token, or missing tty just makes the POST a silent
# no-op (curl is backgrounded with a tight --max-time and all output discarded),
# and the script always `exit 0`s immediately.
#
# Setup:
#   1. Copy this script to ~/.config/ghostty-ramon/claude-hooks/ and chmod +x it.
#   2. Merge settings-hooks.json into ~/.claude/settings.json.
# See AGENT-DASHBOARD.md for the full walkthrough.

# Never let an error here surface to Claude Code.
set +e

# (ramon fork / Agent Manager) Hook-recursion guard. The Agent Manager sidecar
# sets GHOSTTY_AGENT_MANAGER=1 in the environment of any `claude` it spawns, so
# its own (current/future) agent activity does NOT loop back through this hook and
# re-POST agent-state. Exit immediately when set. (In the Phase-0 skeleton the
# sidecar only calls list/annotate MCP tools and spawns no `claude`, so this is a
# no-op today — it's here so the guarantee holds the moment the sidecar gains its
# own agent-spawning capability.)
[ -n "$GHOSTTY_AGENT_MANAGER" ] && exit 0

state="$1"
case "$state" in
  working|waiting|idle) ;;
  *) exit 0 ;;   # unknown/blank state: nothing to report
esac

# --- stdin: the Claude Code hook event JSON (best-effort) --------------------
# We do NOT require it to parse; we only fish out a tool_name / prompt / message
# hint when present so the dashboard tile can show context. Read with a short
# timeout so a hook wired without stdin can't hang us.
stdin_json=""
if [ ! -t 0 ]; then
  stdin_json="$(cat 2>/dev/null)"
fi

# Extract one string field from the (shallow) hook JSON. Prefer python3 for
# correct JSON handling; fall back to a tolerant sed if python3 is absent.
json_field() {
  field="$1"
  [ -n "$stdin_json" ] || return 0
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$stdin_json" | python3 -c '
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(d,dict): sys.exit(0)
v=d.get(sys.argv[1])
if isinstance(v,str): sys.stdout.write(v)
' "$field" 2>/dev/null
  else
    # Tolerant fallback: first "field":"value" occurrence, unescaped naively.
    printf '%s' "$stdin_json" \
      | sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | head -1
  fi
}

tool=""
prompt=""
message=""
case "$state" in
  working)
    # PreToolUse carries tool_name; UserPromptSubmit/SessionStart carry prompt.
    # We extract BOTH unconditionally: a given event only ever carries one, so the
    # other resolves to empty and is omitted from the POST. This is intentional —
    # it keeps one code path for all three "working" triggers.
    tool="$(json_field tool_name)"
    prompt="$(json_field prompt)"
    ;;
  waiting)
    message="$(json_field message)"
    ;;
esac

# --- tty: the surface's controlling terminal ---------------------------------
# Claude Code spawns hooks DETACHED from the controlling terminal, so this
# process's OWN tty is usually the no-tty marker "??" (and the `tty` builtin
# likewise reports "not a tty"). The surface's tty lives on an ANCESTOR — the
# `claude` process itself runs on it. So walk up the ppid chain and take the
# nearest ancestor that has a real tty. Stop at init/no-parent or after a bounded
# number of hops. The FIRST real tty found is the right one (we never reach
# ghostty-host's own "??" because we stop as soon as a tty appears).
tty=""
_pid="$$"
_hops=0
while [ -n "$_pid" ] && [ "$_pid" != "0" ] && [ "$_pid" != "1" ] && [ "$_hops" -lt 12 ]; do
  _t="$(ps -o tty= -p "$_pid" 2>/dev/null | tr -d ' ')"
  case "$_t" in
    ""|"??"|"?") : ;;            # no tty at this level — keep walking up
    *) tty="$_t"; break ;;
  esac
  _pid="$(ps -o ppid= -p "$_pid" 2>/dev/null | tr -d ' ')"
  _hops=$(( _hops + 1 ))
done
# No tty anywhere up the chain -> the MCP handler can't correlate; nothing to do.
[ -n "$tty" ] || exit 0

# --- token: env var, else the per-machine secret file ------------------------
token="${GHOSTTY_MCP_TOKEN:-}"
if [ -z "$token" ]; then
  token="$(sed -n 's/^mcp-token *= *//p' "$HOME/.config/ghostty-ramon/local" 2>/dev/null | head -1)"
fi

# --- stamp-file debounce (the chatty `working`/PreToolUse path ONLY) ---------
# NOTE the debounce applies to ALL `working` events (UserPromptSubmit, PreToolUse,
# AND SessionStart share the `working` arg, so this script cannot tell them apart).
# That is fine: PreToolUse is the chatty one this guards, and in the common turn
# order UserPromptSubmit stamps first and the immediately-following PreToolUse is
# correctly swallowed. The rare reverse edge (a SessionStart stamp <1s before a
# UserPromptSubmit) can drop the prompt POST; that loss is accepted (the prompt
# subtitle is a display hint, and app-side coalescing is a second line of defense).
# `waiting`/`idle` (Notification/Stop/SessionEnd) are rare/meaningful and never
# debounced. macOS `stat -f %m` is whole-seconds, so a 1s floor is used when
# sub-second mtime is unavailable (see SPEC §1.4 / §3.1.4).
#
# Security: the stamp lives in a PRIVATE per-user dir ($TMPDIR — per-user 0700
# /var/folders — or, only if unset, ~/.cache/ghostty-ramon which we create). We do
# NOT fall back to world-writable /tmp: a predictable name there (tty names are
# enumerable) under a truncating `: > "$stamp"` redirect would let a local attacker
# pre-create the path as a symlink and have us clobber a victim file. We also write
# under `set -C` (noclobber) so even within the private dir a pre-existing symlink
# is never followed by the truncating create.
if [ "$state" = "working" ]; then
  if [ -n "$TMPDIR" ]; then
    stamp_dir="$TMPDIR"
  else
    stamp_dir="$HOME/.cache/ghostty-ramon"
    mkdir -p "$stamp_dir" 2>/dev/null
  fi
  safe_tty="$(printf '%s' "$tty" | tr '/' '_')"
  stamp="${stamp_dir}/ghostty-agent-${safe_tty}"
  now="$(date +%s)"
  if [ -f "$stamp" ]; then
    # Sub-second where available (GNU stat %.Y); else whole-second macOS stat.
    last="$(stat -f %m "$stamp" 2>/dev/null || stat -c %Y "$stamp" 2>/dev/null)"
    if [ -n "$last" ]; then
      delta=$(( now - last ))
      # 1s floor for the ~750ms intent (whole-second mtime resolution).
      if [ "$delta" -lt 1 ]; then
        exit 0
      fi
    fi
  fi
  # Refresh the stamp's mtime. Under `set -C` (noclobber) a pre-existing symlink at
  # this path makes the create fail instead of following it; in that case `touch`
  # an existing regular file (it won't create through a dangling symlink) so the
  # debounce still advances without ever clobbering a symlink target.
  if [ -f "$stamp" ] && [ ! -h "$stamp" ]; then
    : > "$stamp" 2>/dev/null
  else
    ( set -C; : > "$stamp" ) 2>/dev/null
  fi
fi

# --- JSON-escape a string for safe interpolation -----------------------------
# Drop ALL C0 control bytes (0x00–0x1F, incl. CR/LF/TAB) then escape backslashes
# and double-quotes. A raw control byte (e.g. a TAB in a prompt) is invalid in a
# JSON string per RFC 8259, so JSONSerialization in MCPAgentState.parse would
# reject the whole body (400) and the event would be silently lost; dropping the
# control bytes here keeps the hint best-effort lossy rather than dropping the
# event. (We strip rather than \uXXXX-escape: these are display hints, not data.)
json_escape() {
  printf '%s' "$1" \
    | tr -d '\000-\037' \
    | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

esc_tty="$(json_escape "$tty")"
tool_field=""
prompt_field=""
msg_field=""
[ -n "$tool" ]    && tool_field=",\"tool\":\"$(json_escape "$tool")\""
[ -n "$prompt" ]  && prompt_field=",\"prompt\":\"$(json_escape "$prompt")\""
[ -n "$message" ] && msg_field=",\"message\":\"$(json_escape "$message")\""

body="$(printf '{"tty":"%s","state":"%s"%s%s%s}' \
  "$esc_tty" "$state" "$tool_field" "$prompt_field" "$msg_field")"

# --- fire-and-forget POST ----------------------------------------------------
# Tight --max-time so a hung/absent server never stalls the agent. Backgrounded
# and detached; all output discarded; we exit 0 immediately. The Release MCP
# default port is 8765; GHOSTTY_MCP_PORT overrides for dev builds (8766/8767).
port="${GHOSTTY_MCP_PORT:-8765}"
url="http://127.0.0.1:${port}/agent-state"

if [ -n "$token" ]; then
  # Feed the token header via a curl config file on STDIN (`-K -`) rather than
  # an `-H` argv flag, so the MCP token (a shell-execution credential) never
  # appears in this curl's process argument list, where another local user
  # could snoop it with `ps -ww`. The body still rides argv (it is not secret).
  printf 'header = "X-Ghostty-Token: %s"\n' "$token" \
    | curl -fsS --max-time 2 -K - \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$body" >/dev/null 2>&1 &
else
  curl -fsS --max-time 2 \
    -X POST "$url" \
    -H "Content-Type: application/json" \
    -d "$body" >/dev/null 2>&1 &
fi

exit 0
"""#
}
