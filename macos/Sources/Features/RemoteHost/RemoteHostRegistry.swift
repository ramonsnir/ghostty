import Foundation

/// (ramon fork / cloud-hosts) One parsed entry of the `pty-remote-host` config key —
/// a cloud box the fork can open `.client` splits on over an SSH-forwarded
/// `ghostty-host` socket. `name` is the registry key used everywhere the GUI + sidecar
/// aggregate multiple hosts into one keyspace (D3); it is NEVER `"local"` (that name is
/// reserved for the local `pty-host` scalar). Value type — cheap to pass around and to
/// persist the `name` alongside a session id.
struct RemoteHostEntry: Equatable, Sendable {
    /// The registry key (identity label). Reserved name `"local"` is rejected by the
    /// parser, so a valid entry's name is always a real remote.
    let name: String

    /// The SSH destination passed to `ssh` verbatim (e.g. `user@example.ts.net`, a
    /// `~/.ssh/config` Host alias, or an IPv6 literal). Never string-spliced.
    let sshTarget: String

    /// Absolute (or `~`-relative, expanded on the box by the login shell / ssh) path of
    /// the `ghostty-host` listening socket ON THE REMOTE. This is the `-L` forward's
    /// remote endpoint.
    let remoteSocketPath: String

    /// Optional explicit LOCAL forwarded-socket path. When nil, the tunnel supervisor
    /// derives one under a short 0700 dir (sun_path length is ~104 bytes — D7). Present
    /// only when the user pinned it in the config line's third field.
    let localSocketPath: String?

    /// (ramon fork / cloud-hosts, Phase 6) Optional per-host TRANSPORT-COMMAND override
    /// (from a matching `pty-remote-host-command` line). When present, the tunnel
    /// supervisor runs ONE long-lived forward process built from this command through the
    /// user's LOGIN + INTERACTIVE shell (so a shell FUNCTION resolves) — NO ControlMaster,
    /// NO `ssh -O check`/`-O exit`. When nil (the common case) the host uses the default
    /// `ssh` ControlMaster transport BYTE-IDENTICALLY. With an override present the
    /// `sshTarget` field is only a label; `remoteSocketPath` still applies (it is the `-L`
    /// forward's remote endpoint appended to the command).
    let transportCommand: String?

    init(
        name: String,
        sshTarget: String,
        remoteSocketPath: String,
        localSocketPath: String?,
        transportCommand: String? = nil
    ) {
        self.name = name
        self.sshTarget = sshTarget
        self.remoteSocketPath = remoteSocketPath
        self.localSocketPath = localSocketPath
        self.transportCommand = transportCommand
    }
}

/// (ramon fork / cloud-hosts) The SOLE home of the `pty-remote-host` line grammar
/// (§Config keys). The Zig `RepeatableString` parser stores each line's value verbatim
/// after the config key's first `=` and does NOT trim; ALL structure below is parsed
/// here, Swift-side.
///
/// Grammar (per line, as returned by `Ghostty.Config.ptyRemoteHostLines`):
///
///     <name> = <ssh-target> : <remote-socket-path> [ : <local-socket-path> ]
///
/// Rules:
///   - Split `name` off the remainder on the **first `=`** only (so an `=` inside a
///     later field — unlikely but legal — is preserved).
///   - Split the remainder on the **spaced ` : `** separator (space-colon-space), NOT a
///     bare `:`, so `user@host`, IPv6 `::1`, and `=`-free socket paths never mis-split.
///   - **Trim** every field of surrounding whitespace.
///   - `local` (case-insensitive) is RESERVED → returns nil (it maps to the `pty-host`
///     scalar, never a remote entry).
///   - Anything malformed (no `=`, empty name, fewer than 2 or more than 3 fields, any
///     empty required field) → nil.
enum RemoteHostRegistry {
    /// The spaced separator between the ssh-target / socket fields. A bare `:` is
    /// deliberately NOT used so `user@host`, `::1`, and `host:22` stay intact.
    static let fieldSeparator = " : "

    /// Parse a single `pty-remote-host` line value. Returns nil for the reserved
    /// `local` name and for any malformed line (never throws — a bad line is dropped).
    static func parse(line: String) -> RemoteHostEntry? {
        // Split name off on the FIRST '=' only.
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let name = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        // `local` is reserved for the scalar pty-host; never a remote entry.
        guard name.lowercased() != "local" else { return nil }

        let remainder = String(line[line.index(after: eq)...])
        let parts = remainder
            .components(separatedBy: fieldSeparator)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // Need ssh-target + remote-socket; an optional local-socket makes 3. More than
        // 3 fields is malformed.
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let sshTarget = parts[0]
        let remoteSocketPath = parts[1]
        guard !sshTarget.isEmpty, !remoteSocketPath.isEmpty else { return nil }

        let localSocketPath: String?
        if parts.count == 3 {
            let local = parts[2]
            guard !local.isEmpty else { return nil }
            localSocketPath = local
        } else {
            localSocketPath = nil
        }

        return RemoteHostEntry(
            name: name,
            sshTarget: sshTarget,
            remoteSocketPath: remoteSocketPath,
            localSocketPath: localSocketPath
        )
    }

    /// (Phase 6) Parse a single `pty-remote-host-command` line into a `(name, command)`
    /// pair. Same name-split rule as `parse(line:)` — split on the **first `=`** only, trim
    /// both sides — but the remainder is the WHOLE command template taken VERBATIM (NOT
    /// field-split on ` : `): a transport command can itself contain `:`, `=`, and spaces
    /// (e.g. `my-ssh-wrapper cloud-1 --`). Returns nil for the reserved `local` name (case-
    /// insensitive) and for any malformed line (no `=`, empty name, or empty command).
    static func parseCommand(line: String) -> (name: String, command: String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let name = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        guard name.lowercased() != "local" else { return nil }
        let command = String(line[line.index(after: eq)...])
            .trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        return (name, command)
    }

    /// (Phase 6) Build the `name -> command` map from the raw `pty-remote-host-command`
    /// lines. Malformed / reserved lines are skipped; on a duplicate name the LAST
    /// occurrence wins (config-file layering). A command whose name has no matching
    /// `pty-remote-host` line is simply never consumed by the builder below (there is no
    /// host to attach it to — the remote socket path comes from the host line).
    static func parseCommands(lines: [String]) -> [String: String] {
        var map: [String: String] = [:]
        for line in lines {
            guard let (name, command) = parseCommand(line: line) else { continue }
            map[name] = command
        }
        return map
    }

    /// Build the `name -> entry` registry from the raw config lines. Malformed / reserved
    /// lines are skipped. On a duplicate name the LAST occurrence wins (later config
    /// lines override earlier ones, matching config-file layering).
    ///
    /// (Phase 6) `commandLines` are the raw `pty-remote-host-command` lines; each is paired
    /// by NAME onto the matching host entry as its `transportCommand`. `commandLines`
    /// defaults to empty, so a single-argument `parse(lines:)` (the name/label-only callers)
    /// stays BYTE-IDENTICAL — every entry then has `transportCommand == nil` and uses the
    /// default `ssh` ControlMaster transport.
    static func parse(
        lines: [String],
        commandLines: [String] = []
    ) -> [String: RemoteHostEntry] {
        let commands = parseCommands(lines: commandLines)
        var registry: [String: RemoteHostEntry] = [:]
        for line in lines {
            guard let base = parse(line: line) else { continue }
            registry[base.name] = RemoteHostEntry(
                name: base.name,
                sshTarget: base.sshTarget,
                remoteSocketPath: base.remoteSocketPath,
                localSocketPath: base.localSocketPath,
                transportCommand: commands[base.name])
        }
        return registry
    }
}
