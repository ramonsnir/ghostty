import SwiftUI
import AppKit
import GhosttyKit

/// (ramon fork / Agent Dashboard, Layer 3) One row: a full-width card with a
/// compact header (badge · title · bell dot · keep 📌 · close ⊗ · hide 👁⃠), a live (or metadata-only)
/// preview showing the agent's LATEST rows, and a dim footer. READ-ONLY:
/// clicking the card jumps to the real split (present + unzoom). No inline reply
/// / key forwarding (LOCKED #3).
struct AgentPreviewTile: View {
    let entry: AgentEntry
    let ghostty: Ghostty.App
    /// When false (pty-host off), render a metadata-only tile (no mirror).
    let previewsEnabled: Bool
    /// (ramon fork / Agent Dashboard) True when this tile is the split the user is
    /// currently focused on in the terminal — gets a LIGHT "you're looking at this"
    /// treatment (a thin accent border + a small header dot). Purely cosmetic.
    let isFocused: Bool
    /// (ramon fork / Agent Dashboard) True when this tile is spotlighted to the
    /// top via `spotlight_dashboard_split` — a stronger accent border + a header up-arrow
    /// badge. (The list also floats it above every section for its duration.)
    let isSpotlighted: Bool
    /// (ramon fork / Agent Dashboard) Dismiss this tile's spotlight now — wired to a
    /// click on the up-arrow badge (the manual early-out, same as re-pressing the
    /// keybind). No-op unless `isSpotlighted`.
    let onDismissSpotlight: () -> Void
    let onHide: () -> Void
    /// (ramon fork / Agent Dashboard) Acknowledge this split's bell + promoted attention
    /// from the tile's 🔔 icon WITHOUT focusing it — drops the signal system-wide so it
    /// can re-fire later. Routes to `AgentDashboardModel.dismissBell`. No-op unless
    /// `bellRinging`.
    let onDismissBell: () -> Void
    /// Force-close this split + free its (queue) slot — the escape hatch for a wedged
    /// queue agent. Gated behind a confirmation (no undo: it ends the agent).
    let onClose: () -> Void
    /// (keep) Toggle this queue split's KEEP state — exempt it from the queue's auto-close so
    /// you can do manual work after the task is done (or un-keep it). The argument is the
    /// DESIRED new value (true = keep, false = allow auto-close). Queue tiles only.
    let onKeep: (Bool) -> Void

    // MARK: - Adopt-into-a-queue inputs (ramon fork / Agent Queue, adopt)

    /// (adopt) The names of the queue runs currently present. Empty ⇒ the Adopt button is
    /// DISABLED (LOCKED #4: nothing to adopt into); a single name ⇒ the modal auto-selects
    /// it + hides the picker.
    let queueRuns: [String]
    /// (adopt) LOCAL graph-node lookup (LOCKED #1): for a (run, key) returns the node's
    /// title + url when the key is on that run's `report_queue_graph` board, else nil
    /// (off-board: no title, still adoptable). Instant, no round-trip.
    let nodeForKey: (_ run: String, _ key: String) -> (title: String?, url: String?)?
    /// (adopt) The GUI-visible running keys for a run — the modal's duplicate-key guard
    /// source.
    let activeKeysForRun: (_ run: String) -> Set<String>
    /// (adopt) The Haiku-inferred key suggestion for THIS surface (entry.annotation?.
    /// queueKeySuggested): nil ⇒ inferring / unknown; "" ⇒ inferred nothing; non-empty ⇒
    /// the prefill candidate.
    let suggestedKey: String?
    /// (adopt) Request an on-demand Haiku inference of the work-item key for `surfaceUUID`
    /// against `run`'s candidate vocabulary (posts an infer_key command).
    let onRequestInfer: (_ surfaceUUID: UUID, _ run: String) -> Void
    /// (adopt) Confirm adoption: latch + move + annotate (posts an adopt command).
    let onAdoptConfirm: (_ run: String, _ key: String, _ surfaceUUID: UUID, _ url: String?) -> Void
    /// (adopt) "Jump to the running one" on a duplicate-key collision.
    let onJumpToKey: (_ run: String, _ key: String) -> Void

    // MARK: - Promote / demote to HERO inputs (ramon fork / Hero Agents)

    /// (hero) Promote this QUEUE split into a HERO — eject to its own tab + flip the hero bit
    /// (posts a `promote` command). Offered only on a queue-owned, non-hero tile.
    let onPromoteToHero: () -> Void
    /// (hero) Demote this HERO split back to a regular tracked item (posts a `demote`
    /// command). Offered only on a queue-owned tile that IS a hero.
    let onDemoteFromHero: () -> Void

    @State private var hovering = false
    @State private var confirmClose = false

    // MARK: - Adopt modal state (ramon fork / Agent Queue, adopt)
    @State private var showAdopt = false
    @State private var adoptRun: String = ""
    @State private var adoptKey: String = ""
    @State private var inferring = false

    // MARK: - Mirror auto-reconnect state (ramon fork / Agent Dashboard)
    //
    // The live preview is a READ-ONLY `.client` mirror to `ghostty-host` with a
    // SINGLE-SHOT connection and NO retry in the Zig client — any socket blip
    // (EOF / read error / decode error / a routine host hiccup) makes the read
    // thread call `markMirrorEnded` and EXIT, freezing the preview forever until a
    // full GUI restart (`src/termio/Client.zig`). The tile keys the mirror
    // SurfaceView on `\(sessionID)-\(mirrorGeneration)`, so bumping the generation
    // recreates it with a fresh connection. `AgentMirrorPreview` polls
    // `surfaceView.processExited` (set true when `markMirrorEnded` synthesizes a
    // `child_exited`) and calls back here to drive a NEVER-GIVE-UP backoff reconnect
    // — a few quick attempts, then a steady once-a-minute retry that persists for as
    // long as the REAL split is alive. GUI-only, self-healing, no host restart.
    @State private var mirrorGeneration = 0
    /// Reconnect attempts spent since the last time the mirror was healthy. Drives the
    /// backoff curve; reset by `handleMirrorStable` once a fresh connection stays up,
    /// and by `retryMirror`. It grows unbounded (we never give up) — only the delay
    /// curve reads it, and it saturates at the steady interval.
    @State private var mirrorAttempts = 0
    /// True while a reconnect timer is ARMED and hasn't fired yet (the preview is
    /// currently frozen, waiting out the backoff). Drives the "reconnect now" button
    /// that lets the user skip a long wait; NOT a give-up flag (we always retry).
    @State private var mirrorReconnectPending = false
    /// Monotonic token that invalidates a scheduled reconnect timer when the user
    /// forces an immediate retry or the mirror goes stable, so a stale timer can't
    /// bump the generation a second time (double-remount).
    @State private var mirrorReconnectToken = 0

    /// Number of fast exponential attempts (delays 1,2,4,8,16,30) before the backoff
    /// settles into the steady once-a-minute interval. Also the point at which the
    /// manual "reconnect now" affordance appears (waits are now ≥30s).
    private static let quickReconnectAttempts = 6
    /// Steady reconnect interval (seconds) once the quick burst is spent — we keep
    /// retrying at this cadence forever (no cap) while the real split is alive.
    static let steadyReconnectDelay: TimeInterval = 60
    /// Seconds a fresh mirror must stay connected before we consider it healthy and
    /// reset the backoff budget (so a LATER transient drop gets a full retry budget).
    static let mirrorStableSeconds: TimeInterval = 15

    /// Backoff delay (seconds) before reconnect attempt `attempt` (0-based): a quick
    /// exponential burst 1, 2, 4, 8, 16, 30 for the first `quickReconnectAttempts`,
    /// then a STEADY `steadyReconnectDelay` (60s) forever — never give up. Pure +
    /// static for unit testing.
    static func mirrorReconnectDelay(attempt: Int) -> Double {
        let a = max(attempt, 0)
        if a >= quickReconnectAttempts { return steadyReconnectDelay }
        return min(Double(1 << a), 30.0)
    }

    /// The mirror preview reported its socket ended. If the REAL split's process is
    /// still alive this is a transient drop → schedule a backoff reconnect (forever;
    /// the steady 60s cadence after the quick burst). If the real process ALSO exited,
    /// the session is genuinely gone (the detector will drop this tile shortly) so we
    /// do nothing and let it vanish — that gate is what bounds the infinite retry.
    private func handleMirrorEnded() {
        guard let real = entry.realView, !real.processExited else { return }
        let attempt = mirrorAttempts
        mirrorAttempts += 1
        mirrorReconnectPending = true
        let session = entry.sessionID
        let token = mirrorReconnectToken
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.mirrorReconnectDelay(attempt: attempt)) {
            // Only recreate if we're still the same session and this scheduled timer
            // hasn't been superseded by a manual retry / a stable reset in the meantime.
            guard entry.sessionID == session, mirrorReconnectToken == token else { return }
            mirrorReconnectPending = false
            mirrorGeneration &+= 1
        }
    }

    /// A fresh mirror connection has stayed up long enough to be healthy — reset the
    /// backoff so a future transient drop starts a full retry budget from scratch.
    private func handleMirrorStable() {
        mirrorReconnectToken &+= 1
        mirrorAttempts = 0
        mirrorReconnectPending = false
    }

    /// Manual "reconnect now" — skip the remaining backoff wait and mount a fresh
    /// mirror immediately, restarting the quick-attempt burst. Invalidates any pending
    /// timer so it can't double-bump the generation afterward.
    private func retryMirror() {
        mirrorReconnectToken &+= 1
        mirrorAttempts = 0
        mirrorReconnectPending = false
        mirrorGeneration &+= 1
    }

    /// Whether to surface the manual "reconnect now" button: only while a reconnect is
    /// pending AND we've entered the slow phase (waits ≥30s), so the user can skip a
    /// long wait without waiting out the full minute. Hidden during the quick burst.
    private var showReconnectNow: Bool {
        mirrorReconnectPending && mirrorAttempts >= Self.quickReconnectAttempts
    }

    /// The fork's bell amber (matches the in-terminal bell border).
    private static let bellAmber = Color(red: 1.0, green: 0.8, blue: 0.0)

    /// (ramon fork / Agent Dashboard) Tile border color, by precedence: a ringing
    /// bell (amber, the loud transient signal) wins; then a spotlight OR the
    /// focused split (accent — "top" / "you're here"); then hover; else none.
    private var frameColor: Color {
        if bellRinging { return Self.bellAmber }
        if isSpotlighted || isFocused { return Color.accentColor }
        // (hero) A hero is marked ONLY by the purple header star (below) — NOT a purple frame,
        // which would fight the amber bell/attention border. The star is the standing marker.
        if hovering { return Color.accentColor.opacity(0.6) }
        return .clear
    }

    /// Border width matching `frameColor`: bell + spotlight are strong (3), the focused hint is
    /// medium (2), hover/none are 1. (No hero border — heroes are marked by the header star.)
    private var frameWidth: CGFloat {
        if bellRinging || isSpotlighted { return 3 }
        if isFocused { return 2 }
        return 1
    }

    /// (ramon fork / Agent hooks) Attention is split into TWO independent signals
    /// that intentionally behave like their real-terminal analogs:
    ///
    /// - `bellRinging` (the REAL bell) drives the amber FRAME (border) + the header
    ///   bell ICON. Like any bell it CLEARS WHEN YOU FOCUS the surface (Ghostty
    ///   resets the surface bell on focus and the dashboard's bell publisher
    ///   follows). This is the transient "something happened" signal.
    /// - `waitingForInput` (the HOOK `.waiting` state) drives the "waiting ⚠" chip
    ///   + the "needs input" pill. It is a STATUS, not a bell: it PERSISTS until the
    ///   agent reports a new state (it does NOT clear on focus), so you can leave a
    ///   waiting tile up on purpose; hiding the split is the manual dismiss. (The
    ///   `.waiting` auto-unhide still fires once on the enters-waiting edge — see
    ///   `AgentDashboardModel.applyAgentState` — so a re-hidden tile re-surfaces
    ///   only on a fresh waiting transition.)
    ///
    /// Keeping the strong frame/icon tied to the bell (not the hook) is deliberate:
    /// the bell's clear-on-focus is what makes leaving a `.waiting` status around
    /// non-annoying.
    /// (ramon fork / Bell Attention) The amber frame + header icon fire for a raw bell
    /// AND for a promoted "attention needed" state (the loud Tier-2 signal). The exact
    /// raw-bell-under-filter cosmetics (e.g. a dimmer dot vs. the full amber frame) are
    /// the deferred bell-features-vs-attention-features visual; today both read as the
    /// existing amber so a promotion is unmistakably visible.
    private var bellRinging: Bool { entry.bell || entry.attention }

    /// (ramon fork / Bell Attention) The surface was explicitly promoted by the Agent
    /// Manager (set_attention) — drives a distinct "needs you" pill.
    private var attentionNeeded: Bool { entry.attention }

    /// (ramon fork / Agent hooks) The agent has reported `.waiting` but ALSO has a
    /// live background shell churning (read from Claude Code's footer — see
    /// `AgentMirrorPreview.backgroundShellCount`). It is then waiting on its OWN
    /// work, not on the user, so the tile is DEMOTED: it shows a neutral
    /// "⚙ background" chip (not the amber "waiting ⚠" nag), keeps the "needs input"
    /// pill hidden, and (model-side) is excluded from
    /// the attention sort + the phone push. When the shell exits and the agent
    /// genuinely turns to the user, a fresh hook event re-arms the real waiting.
    private var hasBackgroundWork: Bool { entry.backgroundShells > 0 }
    private var waitingForInput: Bool { entry.agentState == .waiting && !hasBackgroundWork }

    /// Fixed height of the preview area. Kept deliberately SHORTER than a
    /// full-width terminal scales to, so the bottom-anchored mirror clips the
    /// top and the agent's most-recent rows ("latest progress") stay visible
    /// (request #3).
    private static let previewHeight: CGFloat = 220

    /// True when this tile belongs to a queue run (carries a `queueName` annotation) —
    /// the only case where the destructive force-Close button is offered.
    private var isQueueOwned: Bool {
        !(entry.annotation?.queueName ?? "").isEmpty
    }

    /// (keep) Whether this split is KEPT — exempt from the queue's auto-close (the supervisor
    /// stamps `queueKeep` each sweep). Drives the 📌 pin's filled/outline state.
    private var isKept: Bool {
        entry.annotation?.queueKeep ?? false
    }

    /// (ramon fork / Hero Agents) Whether this split is a HERO (the supervisor stamps
    /// `queueHero` each sweep; the GUI optimistically flips it on promote/demote). Drives the
    /// hero glyph badge + a distinct tile border, and gates the Promote/Demote button label.
    private var isHero: Bool {
        entry.annotation?.queueHero ?? false
    }

    /// (hero) The hero marker color — a purple `star.fill` glyph (NOT a border, which would fight
    /// the amber bell frame). Matches the backlog hero star AND the across-tabs titlebar tab
    /// marker (all purple `star.fill`), so a hero reads consistently in the chrome + the dashboard.
    private static let heroPurple = Color.purple

    /// (Schedules) Whether this tile is a recurring SCHEDULE scan-agent run (its annotation's
    /// `queueSchedule`). Drives a distinct clock glyph — a NON-purple tint so it never reads as
    /// a hero.
    private var isSchedule: Bool {
        entry.annotation?.queueSchedule ?? false
    }
    /// (Schedules) The schedule marker color — teal, distinct from the hero purple + the amber bell.
    private static let scheduleTeal = Color.teal

    var body: some View {
        VStack(spacing: 0) {
            header
            preview
            footer
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(frameColor, lineWidth: frameWidth)
        )
        .shadow(radius: hovering ? 6 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(entry.agent?.command ?? "agent") — \(entry.title)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            badge
            if let marker = originMarker {
                marker
            }
            if entry.agentState != nil {
                stateChip
            }
            Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            // (ramon fork / Agent Dashboard) Light "top" / "you're here" markers.
            // A spotlight (up-arrow) takes precedence over the focused dot when a
            // tile is both. Distinct from the queue KEEP pushpin (pin.fill) below.
            if isSpotlighted {
                Button(action: onDismissSpotlight) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .dashboardTooltip("Dismiss spotlight")
            } else if isFocused {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(Color.accentColor)
                    .dashboardTooltip("Focused split")
            }
            if bellRinging {
                // REAL-bell affordance only. Clears on focus (bell-tied); the hook
                // `.waiting` status uses the "waiting ⚠" chip + "needs input" pill
                // instead, which persist. Now also a CLICK target: acknowledge the bell
                // + attention across the whole system (drop the amber frame / 🔔 title /
                // dock badge / this mark / "needs you" pill) without focusing the split,
                // leaving it free to ring again later.
                Button(action: onDismissBell) {
                    Image(systemName: "bell.badge.fill")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Self.bellAmber)
                .dashboardTooltip("Dismiss bell")
            }
            // (hero) A persistent HERO glyph — shown whenever this split is a hero (queue
            // tiles only), so a load-bearing hero is obvious without hovering. Distinct from
            // the keep 📌 pin (a hero is keep-by-default, but keep is a separate control) and
            // the amber bell: a purple filled star, matching the backlog star + the titlebar tab
            // marker (all purple `star.fill`; the hero is marked by the star, not a border).
            if isQueueOwned && isHero {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(Self.heroPurple)
                    .dashboardTooltip("Hero split")
            }
            // (Schedules) A teal recurring-clock glyph marks a scheduled scan-agent split (queue
            // tiles only) — a low-cognition maintenance run. Distinct tint from the hero star.
            if isQueueOwned && isSchedule {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(Self.scheduleTeal)
                    .dashboardTooltip("Scheduled scan")
            }
            // (keep) The 📌 pin toggle — queue WORK-ITEM tiles only. Shown PERSISTENTLY when
            // kept (so a pinned split is obvious without hovering) and on hover otherwise.
            // Filled + accent when kept; outline + secondary when not. Clicking flips the keep
            // state (optimistic; the supervisor's set_keep confirms it). It's the "exempt this
            // split from auto-close so I can keep working" control. HIDDEN on a schedule tile:
            // a schedule has NO queueKey, so `set_keep{run,key:"",…}` is dropped by the
            // controller's `!key.isEmpty` guard (the pin looked live but "wouldn't click"); and
            // keep is meaningless for a schedule anyway — its lifecycle is cadence-driven, not
            // per-completion. `!isSchedule` gates it out.
            if isQueueOwned && !isSchedule && (isKept || hovering) {
                Button { onKeep(!isKept) } label: {
                    Image(systemName: isKept ? "pin.fill" : "pin")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isKept ? Color.accentColor : Color.secondary)
                .dashboardTooltip(isKept ? "Kept — click to unpin" : "Keep open")
            }
            if hovering {
                // (adopt) Offered ONLY on a NON-queue agent tile (a free, human-created
                // CLI-agent split): pull it into a running queue. Disabled when no queue is
                // running (LOCKED #4) so the affordance is discoverable but inert.
                if !isQueueOwned, entry.agent != nil {
                    Button { startAdopt() } label: {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .disabled(queueRuns.isEmpty)
                    .dashboardTooltip(queueRuns.isEmpty ? "Adopt (no queue running)" : "Adopt into queue")
                }
                // (hero) Promote / demote — queue-owned WORK-ITEM agent tiles only (a hero is a
                // tracked work item). "Promote to Hero" ejects the split into its own tab + flips
                // the hero bit; on a hero it's "Demote" (back to a regular tracked item, stays in
                // its tab). A purple star(.slash) reads as the hero identity, distinct from the
                // red destructive Close and the keep 📌 pin. HIDDEN on a schedule tile: a schedule
                // is not a keyed work item (no assignment to promote/demote), so `!isSchedule`
                // gates it out — Close + Hide remain (both are generic, surface-UUID based).
                if isQueueOwned, !isSchedule, entry.agent != nil {
                    Button { isHero ? onDemoteFromHero() : onPromoteToHero() } label: {
                        Image(systemName: isHero ? "star.slash" : "star")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(isHero ? Color.secondary : Self.heroPurple)
                    .dashboardTooltip(isHero ? "Demote from hero" : "Promote to hero")
                }
                // Force-close is offered ONLY for queue-owned tiles: it's the escape hatch
                // for a wedged queue slot. On a non-queue agent it would be an unscoped
                // "kill this terminal" sitting next to the harmless Hide — needless risk.
                if isQueueOwned {
                    // DESTRUCTIVE: kill the agent + free the slot. A red stop-sign octagon
                    // reads as "terminate this" and is visually distinct from the soft,
                    // reversible Hide (eye.slash) so the two are never confused. Still gated
                    // behind a confirmation dialog (no undo).
                    Button { confirmClose = true } label: {
                        Image(systemName: "xmark.octagon")
                            .font(.caption2)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .dashboardTooltip("Close split")
                }
                // SOFT / reversible: declutter the dashboard — the split keeps running and
                // re-surfaces on a bell / waiting. `eye.slash` (the canonical "hide from
                // view", pairing with the Show affordance) + secondary color keep it clearly
                // distinct from the red destructive Close.
                Button(action: onHide) {
                    Image(systemName: "eye.slash")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .buttonStyle(.borderless)
                .dashboardTooltip("Hide tile")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .contentShape(Rectangle())
        .onTapGesture { jump() }
        .confirmationDialog(
            "Close “\(entry.title)”?",
            isPresented: $confirmClose,
            titleVisibility: .visible
        ) {
            Button("Close split", role: .destructive, action: onClose)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Force-closes this split and ends the agent running in it, discarding any in-progress work. If it's a queue agent, this frees its queue slot so the queue can move on.")
        }
        .sheet(isPresented: $showAdopt) { adoptSheet }
    }

    // MARK: - Adopt-into-a-queue modal (ramon fork / Agent Queue, adopt)

    /// Open the adopt modal: auto-select the single run (else leave empty for the
    /// picker), reset the key field, enter the inferring state, and kick off the
    /// on-demand Haiku key inference against the chosen run.
    private func startAdopt() {
        adoptRun = queueRuns.count == 1 ? queueRuns[0] : ""
        adoptKey = ""
        inferring = true
        showAdopt = true
        // Infer only with a chosen run; the multi-run "" case re-fires on the picker's
        // onChange (see the picker below).
        onRequestInfer(entry.id, adoptRun)
    }

    /// True iff the entered key is already RUNNING in the target run (GUI-visible proxy
    /// for the sidecar's authoritative `run.active.has(key)` guard) — blocks Confirm and
    /// offers a jump instead of creating a key collision.
    private var adoptIsDuplicate: Bool {
        !adoptKey.isEmpty && activeKeysForRun(adoptRun).contains(adoptKey)
    }

    @ViewBuilder
    private var adoptSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Adopt this split into a queue")
                .font(.headline)

            // Queue picker — hidden (shown as static text) when exactly one run.
            if queueRuns.count == 1 {
                Text("Queue: \(adoptRun)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Queue", selection: $adoptRun) {
                    Text("Choose a queue…").tag("")
                    ForEach(queueRuns, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: adoptRun) { newRun in
                    // Re-infer against the newly-chosen run's candidate vocabulary (the
                    // initial infer in startAdopt ran with run == "" and early-returned).
                    guard !newRun.isEmpty else { return }
                    inferring = true
                    onRequestInfer(entry.id, newRun)
                }
            }

            // Key field — prefilled by the Haiku suggestion, with an inferring spinner.
            VStack(alignment: .leading, spacing: 4) {
                TextField("Issue / work-item key", text: $adoptKey)
                    .textFieldStyle(.roundedBorder)
                    .overlay(alignment: .trailing) {
                        if inferring && adoptKey.isEmpty {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("inferring…")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.trailing, 6)
                        }
                    }
                // Live title preview (LOCAL graph lookup — instant, no round-trip).
                if let t = nodeForKey(adoptRun, adoptKey)?.title, !t.isEmpty {
                    Text(t)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if !adoptKey.isEmpty {
                    Text("Not on this queue's board — adoptable, but no title")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Duplicate-key guard + jump affordance.
            if adoptIsDuplicate {
                HStack(spacing: 8) {
                    Text("Already running in this queue.")
                        .font(.caption)
                        .foregroundStyle(Self.bellAmber)
                    Button("Jump to the running one") {
                        onJumpToKey(adoptRun, adoptKey)
                        showAdopt = false
                    }
                    .buttonStyle(.link)
                }
            }

            // KEEP-pin protection note (LOCKED #3).
            Text("On status=done this split auto-closes unless its 📌 KEEP pin is set. The pin protects an adopted split from auto-close.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { showAdopt = false }
                    .keyboardShortcut(.cancelAction)
                Button("Adopt") {
                    onAdoptConfirm(adoptRun, adoptKey, entry.id, nodeForKey(adoptRun, adoptKey)?.url)
                    showAdopt = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(adoptRun.isEmpty || adoptKey.isEmpty || adoptIsDuplicate)
            }
        }
        .padding(16)
        .frame(width: 420)
        // Observe the Haiku suggestion arriving via the annotation path: drop the
        // inferring state, and prefill the field only if the user hasn't typed yet.
        .onChange(of: suggestedKey) { suggestion in
            guard let suggestion else { return }   // nil ⇒ still inferring/unknown
            inferring = false
            if !suggestion.isEmpty && adoptKey.isEmpty { adoptKey = suggestion }
        }
        // Belt-and-suspenders timeout: a never-arriving reply doesn't spin forever.
        // Tied to `inferring` identity so a re-infer (picker change) restarts it.
        .task(id: inferring) {
            guard showAdopt, inferring else { return }
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { inferring = false }
        }
    }

    private var badge: some View {
        Text(entry.agent?.command ?? "•")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18))
            .clipShape(Capsule())
    }

    /// (ramon fork / Agent Queue, §11) The per-tile ORIGIN marker: a small badge
    /// naming the owning queue, plus the work-item KEY when present. Rendered ONLY
    /// for QUEUE tiles (those carrying a `queueName` annotation) — a non-queue tile
    /// (the `(other)` origin) shows no extra marker, keeping legacy tiles uncluttered.
    /// All text is rendered via `Text` (SwiftUI escapes it — `textContent`-safe; the
    /// queue name/key are untrusted template/annotation data).
    private var originMarker: AnyView? {
        guard let name = entry.annotation?.queueName, !name.isEmpty else { return nil }
        let key = entry.annotation?.queueKey
        let label = (key?.isEmpty == false) ? "\(name) · \(key!)" : name
        return AnyView(
            Text(label)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                // High-contrast: white on a solid accent fill (was accent-on-faint-accent,
                // i.e. blue-on-dark-blue, which was hard to read).
                .foregroundStyle(Color.white)
                .background(Color.accentColor)
                .clipShape(Capsule())
                .dashboardTooltip("Queue: \(name)" + (key.map { " · \($0)" } ?? ""))
        )
    }

    /// (ramon fork / Agent Queue, §11) The clickable work-item URL link, shown in
    /// the footer for a queue tile that carries a `queueUrl`. Uses `Link` (SwiftUI
    /// escapes the visible text — `textContent`-safe). Only http(s) URLs are made
    /// clickable; any other/garbage value is shown as plain text (never opened).
    @ViewBuilder
    private var queueURLLink: some View {
        if let urlString = entry.annotation?.queueUrl, !urlString.isEmpty {
            if let url = URL(string: urlString),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                Link(destination: url) {
                    Label(urlString, systemImage: "link")
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            } else {
                Text(urlString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// (ramon fork / Agent hooks) The hook-reported lifecycle state chip:
    /// `working` (blue), `waiting ⚠` (amber, matching the bell visual), `idle`
    /// (dim/secondary). Rendered only when `entry.agentState != nil`.
    @ViewBuilder
    private var stateChip: some View {
        switch entry.agentState {
        case .working:
            chip("working", fg: .blue, bg: Color.blue.opacity(0.18))
        case .waiting:
            // Background-busy → neutral "⚙ background" (it's working on its own
            // shell, not nagging); otherwise the amber "waiting ⚠" needs-you chip.
            if hasBackgroundWork {
                chip("⚙ background", fg: .blue, bg: Color.blue.opacity(0.18))
            } else {
                chip("waiting ⚠", fg: Self.bellAmber, bg: Self.bellAmber.opacity(0.2))
            }
        case .idle:
            chip("idle", fg: .secondary, bg: Color.secondary.opacity(0.15))
        case .none:
            EmptyView()
        }
    }

    private func chip(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(fg)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(bg)
            .clipShape(Capsule())
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        // `ghostty.app == nil` only during early-launch / teardown; guarding here
        // keeps a thumbnail strictly non-crashing (AgentMirrorPreview force-reads
        // the app object) and falls through to the "Preview unavailable"
        // placeholder, never a blank rectangle.
        if previewsEnabled, entry.sessionID != 0, ghostty.app != nil, let realView = entry.realView {
            // NOTE: hit-testing is NOT disabled here — the inner ScrollView needs
            // it to scroll, and the mirror SurfaceView itself is made inert inside
            // AgentMirrorPreview so it never steals the click. Taps still bubble to
            // the card's tap-to-jump.
            AgentMirrorPreview(
                ghostty: ghostty,
                sessionID: entry.sessionID,
                realSurface: realView,
                onEnded: { handleMirrorEnded() },
                onStable: { handleMirrorStable() })
                .frame(maxWidth: .infinity)
                .frame(height: Self.previewHeight)
                // Fill the whole preview rectangle with the THEME terminal
                // background so a split narrower than `referenceColumns` (which
                // renders left-aligned with empty space on the right — see
                // AgentMirrorPreview) blends seamlessly into the mirror instead of
                // showing the tile's control-background. Read from config (the
                // `background` color), never hard-coded; the mirror surface paints
                // the same color under its cells, so the seam is invisible.
                .background(ghostty.config.backgroundColor)
                .clipped()
                // (ramon fork / Agent Manager) The Haiku summary, shown LARGE +
                // semi-transparent over the TOP of the live preview so it's readable
                // at a glance, and FADED OUT on hover to reveal the terminal beneath.
                .overlay(alignment: .top) { summaryOverlay }
                // A manual "reconnect now" affordance, shown while a reconnect is
                // pending in the slow (once-a-minute) phase so the user can skip the
                // wait — auto-reconnect never gives up, so this is optional.
                .overlay(alignment: .topTrailing) { if showReconnectNow { mirrorRefreshButton } }
                // Re-create the mirror SurfaceView when the session id changes OR when
                // `mirrorGeneration` is bumped by the auto-reconnect / manual Refresh
                // path — a new id tears down the dead `.client` connection and mounts a
                // fresh one. (The @StateObject is otherwise keyed only by the ForEach
                // UUID, so it would keep the old, dead session.)
                .id("\(entry.sessionID)-\(mirrorGeneration)")
                .contentShape(Rectangle())
                .onTapGesture { jump() }
        } else {
            ZStack {
                Color.black.opacity(0.04)
                Text("Preview unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.previewHeight)
            .contentShape(Rectangle())
            .onTapGesture { jump() }
        }
    }

    /// (ramon fork / Agent Dashboard) Manual "reconnect now" button, shown over the
    /// top-trailing corner while a reconnect is pending in the slow (once-a-minute)
    /// phase. Auto-reconnect keeps trying on its own; a click just skips the wait and
    /// mounts a fresh mirror connection immediately, restarting the quick burst.
    private var mirrorRefreshButton: some View {
        Button(action: retryMirror) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .background(Circle().fill(.background).padding(2))
        }
        .buttonStyle(.plain)
        .dashboardTooltip("Reconnect preview")
        .padding(6)
    }

    // MARK: - Summary overlay

    /// (ramon fork / Agent Manager) The Haiku summary as a LARGE, semi-transparent
    /// frosted band over the TOP of the live preview — readable at a glance without
    /// stealing its own row (the old tiny footer line). It FADES OUT on hover so the
    /// terminal underneath is fully revealed; `.allowsHitTesting(false)` keeps taps
    /// (jump) + scroll passing through to the mirror. Absent ⇒ nothing drawn (the raw
    /// preview shows), so a manager-less / un-summarized tile is unchanged.
    @ViewBuilder
    private var summaryOverlay: some View {
        if let summary = entry.annotation?.summary, !summary.isEmpty {
            Text(summary)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial)
                .opacity(hovering ? 0 : 0.92)
                .animation(.easeInOut(duration: 0.15), value: hovering)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        // (ramon fork / Agent Manager) When the summary is absent, a working tile
        // still shows its latest prompt as a small subtitle (the summary itself now
        // renders LARGE over the preview — see `summaryOverlay`). The colored state
        // chip in the header reflects the authoritative hook state (design §5.1).
        if entry.annotation?.summary == nil || entry.annotation!.summary!.isEmpty,
           entry.agentState == .working, let prompt = entry.lastPrompt, !prompt.isEmpty {
            Text(prompt)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
        }
        HStack(spacing: 6) {
            Text((entry.pwd as NSString).lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            // Surface the last tool name while the agent is working
            // (ramon fork / Agent hooks).
            if entry.agentState == .working, let tool = entry.lastTool, !tool.isEmpty {
                Text("⛭ \(tool)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if attentionNeeded {
                // (ramon fork / Bell Attention) The Agent Manager promoted this surface
                // (e.g. a bell it judged worth interrupting you for). Cleared on focus.
                pill("needs you", color: Self.bellAmber)
            } else if waitingForInput {
                // Hook-driven status: persists until the agent reports a new state
                // (NOT cleared by focus, unlike the bell frame/icon).
                pill("needs input", color: Self.bellAmber)
            } else if entry.agentState == .waiting, hasBackgroundWork {
                // Demoted waiting: a quiet, NON-amber info pill (it isn't a nag —
                // the agent is waiting on its own background shell, not the user).
                pill(
                    entry.backgroundShells == 1
                        ? "1 shell running"
                        : "\(entry.backgroundShells) shells running",
                    color: .secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 16)
        // (ramon fork / Agent Queue, §11) The clickable work-item URL for a queue
        // tile, shown below the metadata row. Absent (zero height) for non-queue
        // tiles or a queue tile with no url.
        queueURLLink
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.2))
            .clipShape(Capsule())
    }

    // MARK: - Jump

    private func jump() {
        guard let view = entry.realView else { return }
        // Defer to the next runloop so the present runs AFTER AppKit finishes
        // making the dashboard panel the key window from THIS click. The panel
        // is `canBecomeKey` (the tiles must take clicks), so a click makes it
        // key as part of the in-flight mouse event. If we posted synchronously,
        // `ghosttyDidPresentTerminal`'s `makeKeyAndOrderFront` would run before
        // that settles and the panel could re-grab key afterward — leaving the
        // target window frontmost but NOT key, so its surface never truly gains
        // focus (no cursor blink, dropped keystrokes) until you click away and
        // back. Running on the next runloop makes the target take key last.
        DispatchQueue.main.async {
            for controller in TerminalController.all {
                for v in controller.surfaceTree where v.id == view.id {
                    controller.unzoomIfHidden(v)
                    NotificationCenter.default.post(
                        name: Ghostty.Notification.ghosttyPresentTerminal,
                        object: v
                    )
                    return
                }
            }
        }
    }
}

/// (ramon fork / Agent Dashboard, Layer 3) The embedded read-only mirror. Builds
/// a `Ghostty.SurfaceView` with `mirror = true` + the host session id, then lets
/// the existing SurfaceWrapper render it natively (full color, viewport-only —
/// exactly right for a thumbnail).
///
/// Scaling: the mirror renders the HOST's grid at a FIXED cell size (it does NOT
/// scale the font to fit the view — it draws cells top-aligned and clips/pads the
/// rest). So to show the agent's LATEST (bottom) rows we must frame the mirror at
/// the grid's NATURAL size — every host row renders, nothing clipped — and THEN
/// scale that down to the preview width, bottom-anchored, clipping the top.
///
/// The catch: a `.client` MIRROR surface's own `surfaceSize` reports
/// `columns`/`rows`/`width_px` that track the VIEW frame we set (its core
/// `size.screen` follows the frame), so they cannot tell us the host grid — using
/// them feeds back and collapses the view. We instead read the host grid from the
/// REAL surface (`realSurface`), whose `size.screen` IS the host framebuffer, so
/// its `columns`/`rows` are the authoritative host grid. The per-cell pixel size
/// comes from the mirror itself (font metrics — frame-independent and stable).
/// `@ObservedObject` on `realSurface` keeps the preview correct across host
/// resizes. Hit-testing is disabled at the call site so the CARD (not the mirror)
/// receives the click.
struct AgentMirrorPreview: View {
    /// Injected into the SurfaceWrapper's `@EnvironmentObject` — without this the
    /// wrapper traps ("No ObservableObject of type App found") the moment a live
    /// preview mounts. Every other SurfaceWrapper mount injects it.
    let ghostty: Ghostty.App
    let sessionID: UInt64

    /// The REAL terminal surface for this session. Its `surfaceSize` is the
    /// authoritative HOST grid (unlike the mirror's, which tracks our frame).
    @ObservedObject var realSurface: Ghostty.SurfaceView

    @StateObject private var surfaceView: Ghostty.SurfaceView

    /// (ramon fork / Agent Dashboard) Called once when this mirror's `.client`
    /// connection ends (`surfaceView.processExited` flips true via the synthetic
    /// `child_exited` that `markMirrorEnded` pushes). The parent drives a
    /// never-give-up backoff reconnect. Default no-op keeps other call sites (tests) valid.
    var onEnded: () -> Void = {}
    /// (ramon fork / Agent Dashboard) Called once when a fresh connection has stayed
    /// up for `mirrorStableSeconds` — the parent resets its reconnect backoff budget.
    var onStable: () -> Void = {}

    /// Number of trailing rows to drop below the bottom-anchored thumbnail —
    /// empty rows PLUS an information-less footer (the agent's input box + its
    /// mode/status lines) — so the preview rises to the last row of actual
    /// CONTENT. Computed by `chromeTrailingSkip` from the real surface's viewport
    /// text, polled on a light timer (live frames render off the Metal path, not
    /// SwiftUI, so an observer wouldn't fire).
    @State private var skipRows: Int = 0

    /// Last-known-good HOST grid geometry, remembered across renders so the preview
    /// stays correctly sized when the real split is temporarily hidden under a
    /// sibling's zoom (its `surfaceSize` goes nil — see the body). A reference box so
    /// it can be updated from inside `body` without tripping SwiftUI state-mutation.
    @State private var hostGeomBox = HostGeomBox()

    init(
        ghostty: Ghostty.App,
        sessionID: UInt64,
        realSurface: Ghostty.SurfaceView,
        onEnded: @escaping () -> Void = {},
        onStable: @escaping () -> Void = {}
    ) {
        self.ghostty = ghostty
        self.sessionID = sessionID
        self.realSurface = realSurface
        self.onEnded = onEnded
        self.onStable = onStable
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.mirror = true
        cfg.sessionID = String(sessionID)
        _surfaceView = StateObject(wrappedValue: Ghostty.SurfaceView(ghostty.app!, baseConfig: cfg))
    }

    var body: some View {
        GeometryReader { geo in
            let backing = surfaceView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2.0
            // Grid + cell size come from the HOST (real) surface, REMEMBERED across
            // frames (`hostGeomBox`). Two reasons this is load-bearing:
            //  1. Cell-size jitter: the mirror's own `cell_width_px` flips ±1px
            //     (17↔16) as its frame re-rounds onto a sub-pixel boundary; feeding
            //     that to the scale caused a ~160 Hz "font size flicker". The host
            //     surface has a fixed frame, so its cell size is stable.
            //  2. Zoom-hidden splits: when this agent's split is hidden under a
            //     SIBLING's zoom, its real `SurfaceView` leaves the view hierarchy and
            //     `realSurface.surfaceSize` goes NIL — but the HOST session's grid did
            //     NOT change (zoom is GUI-only). Without memory the geometry would see
            //     cols=0/cellW=0 and fall into the degenerate width-fit branch (the
            //     "one tile is huge + flickering" bug). So we cache the last VALID host
            //     geometry and keep using it whenever the live read is absent; it's
            //     refreshed the moment the split is shown again.
            let host = realSurface.surfaceSize
            let merged = hostGeomBox.fold(
                hostCols: Int(host?.columns ?? 0), hostRows: Int(host?.rows ?? 0),
                hostCellW: CGFloat(host?.cell_width_px ?? 0),
                hostCellH: CGFloat(host?.cell_height_px ?? 0))
            // Resolve the grid: cache/host → the mirror's OWN client-stream source
            // grid → the mirror's frame size (see resolveGrid). The middle fallback
            // covers a split opened into the dashboard while ALREADY hidden under a
            // sibling's zoom — the real surface was never laid out so the cache is
            // empty, but the .client mirror still received the host's real cols/rows.
            let grid = resolveGrid(merged: merged)
            let rows = grid.rows
            let cellH = grid.cellH
            let g = AgentMirrorPreview.geometry(
                cols: grid.cols, rows: grid.rows, cellW: grid.cellW, cellH: cellH,
                backing: backing, container: geo.size)
            // Skip empty trailing rows + the input-box/mode-line footer: shift
            // the bottom-anchored mirror down so the last row of CONTENT lands at
            // the bottom of the preview (the skipped rows fall below the clip).
            // 0 for a full screen with no detectable footer → unchanged.
            let anchorOffset = AgentMirrorPreview.bottomAnchorOffset(
                skipRows: skipRows, rows: rows,
                cellH: cellH, backing: backing, scale: g.scale)

            // Horizontal scroll for splits wider than `referenceColumns`; narrow
            // splits show left-aligned with empty space on the right. The mirror
            // is scaled UNIFORMLY (g.scale) so cell size is identical across all
            // tiles. `.bottomLeading` anchor keeps column 0 at the scroll origin
            // and the agent's latest (bottom) rows pinned; the top is clipped.
            ScrollView(.horizontal, showsIndicators: true) {
                Ghostty.SurfaceWrapper(surfaceView: surfaceView, isSplit: true)
                    .environmentObject(ghostty)
                    // Make ONLY the mirror NSView inert (so it never grabs the
                    // click / first responder); the enclosing frames + ScrollView
                    // stay hit-testable so scrolling works and taps bubble to the
                    // card's tap-to-jump.
                    .allowsHitTesting(false)
                    .frame(width: g.naturalW, height: g.naturalH)
                    .scaleEffect(g.scale, anchor: .bottomLeading)
                    // Shift down by the skipped-rows height so the last row of
                    // content sits at the bottom (blanks + footer fall below the
                    // clip). Render-only — does not affect layout/measurement.
                    .offset(y: anchorOffset)
                    // Bound the scaled content to its on-screen size so the
                    // ScrollView measures `scaledW` (not the larger unscaled
                    // layout) and clips the top overflow to the preview height.
                    .frame(width: g.scaledW, height: geo.size.height, alignment: .bottomLeading)
                    .clipped()
                    // Mark the mirror UNFOCUSED so its cursor renders as a static
                    // hollow box instead of blinking (blink only happens on a
                    // focused surface — see renderer/cursor.zig). Safe to repeat
                    // (focusCallback no-ops when unchanged); live frames still
                    // render change-driven, so the preview keeps updating.
                    .onAppear {
                        if let surface = surfaceView.surface {
                            ghostty_surface_set_focus(surface, false)
                        }
                        refreshSkipRows()
                    }
                    // Poll tied to view IDENTITY (survives re-renders), unlike a
                    // per-instance Timer.publish which restarts its countdown on
                    // every re-render.
                    .task {
                        // Mount time for the stability gate; both edges fire once per
                        // view identity (a reconnect bumps the tile's .id → fresh task).
                        let mountedAt = Date()
                        var reportedEnded = false
                        var reportedStable = false
                        while !Task.isCancelled {
                            refreshSkipRows()
                            // The mirror's `.client` connection ended (socket EOF /
                            // read error / host-pushed child_exited) → tell the parent
                            // so it can reconnect with backoff. Fire-once per mount.
                            if surfaceView.processExited {
                                if !reportedEnded { reportedEnded = true; onEnded() }
                            } else if !reportedStable,
                                      Date().timeIntervalSince(mountedAt) >= AgentPreviewTile.mirrorStableSeconds {
                                reportedStable = true
                                onStable()
                            }
                            try? await Task.sleep(nanoseconds: 800_000_000)
                        }
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Recompute `skipRows` from the real surface's current viewport text. Under
    /// pty-host the GUI mirror's `cachedVisibleContents` is row-accurate (one
    /// line per grid row, no soft-wrap, blanks preserved) — the dumpText path
    /// terminates every row with a newline, so a single trailing "" is dropped to
    /// land exactly on the grid rows. Cheap (the read is ~500ms-cached).
    private func refreshSkipRows() {
        let text = realSurface.cachedVisibleContents.get()
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let n = AgentMirrorPreview.chromeTrailingSkip(rows: lines)
        if n != skipRows { skipRows = n }
    }

    /// Resolve the grid fed to `geometry`, preferring the remembered HOST geometry
    /// (`merged`), then the mirror's OWN client-stream SOURCE grid, then the mirror's
    /// frame-derived size. The middle step (`ghostty_surface_mirror_grid_size`) is
    /// what fixes a split that's ALREADY hidden under a sibling's zoom when the
    /// dashboard opens: its real `SurfaceView` was never laid out (cache empty,
    /// `realSurface.surfaceSize` nil), but the `.client` mirror still received the
    /// host's real cols/rows in its `grid_frame`. Cell size stays from the cache or
    /// the mirror's own font metrics (display-correct for the dashboard tile). The
    /// C call is GATED on `cols == 0`, so it only runs in that rare fallback.
    private func resolveGrid(merged: HostGeom) -> (cols: Int, rows: Int, cellW: CGFloat, cellH: CGFloat) {
        var cols = merged.cols
        var rows = merged.rows
        if cols == 0, let s = surfaceView.surface {
            let mg = ghostty_surface_mirror_grid_size(s)
            if mg.valid {
                cols = Int(mg.columns)
                rows = Int(mg.rows)
            }
        }
        if cols == 0 {
            cols = Int(surfaceView.surfaceSize?.columns ?? 0)
            rows = Int(surfaceView.surfaceSize?.rows ?? 0)
        }
        // Cell size: prefer the host-cached value (stable). When host was never seen
        // (zoom-hidden at open), the only source is the mirror's OWN `cell_width_px`,
        // which JITTERS (e.g. 15↔17) because the mirror's frame is derived from it and
        // re-rounds each cycle — the same feedback loop the host-sourcing fixed. Font
        // cell size is constant for a thumbnail's life, so LATCH the first non-zero
        // fallback value and hold it; that breaks the loop (a real font/display change
        // re-mounts the tile or arrives via the host once the split is shown).
        let cellW: CGFloat
        let cellH: CGFloat
        if merged.cellW > 0 {
            cellW = merged.cellW
            cellH = merged.cellH
        } else {
            hostGeomBox.fallbackCellW = AgentMirrorPreview.latchedCell(
                prior: hostGeomBox.fallbackCellW,
                candidate: CGFloat(surfaceView.surfaceSize?.cell_width_px ?? 0))
            hostGeomBox.fallbackCellH = AgentMirrorPreview.latchedCell(
                prior: hostGeomBox.fallbackCellH,
                candidate: CGFloat(surfaceView.surfaceSize?.cell_height_px ?? 0))
            cellW = hostGeomBox.fallbackCellW
            cellH = hostGeomBox.fallbackCellH
        }
        return (cols, rows, cellW, cellH)
    }

    /// PURE: latch the FIRST non-zero cell size and HOLD it. Once `prior` is set
    /// (> 0) it wins forever; until then a non-zero `candidate` adopts. This freezes
    /// the host-never-seen fallback cell size so the mirror's own jittering
    /// `cell_width_px` (e.g. 15↔17, from its frame-feedback) can't oscillate the
    /// preview scale. (Font cell size is constant for a thumbnail's life.)
    static func latchedCell(prior: CGFloat, candidate: CGFloat) -> CGFloat {
        prior > 0 ? prior : candidate
    }

    /// The number of columns that fill the preview's WIDTH. This sets a UNIFORM
    /// cell size across every tile regardless of the split's own width: a split
    /// with fewer columns shows with empty space on the right; one with more
    /// columns overflows and is reached via the horizontal scroll bar. Hardcoded
    /// for now (config knob is a follow-up).
    static let referenceColumns: CGFloat = 125

    /// PURE geometry for the mirror preview, factored out for unit testing (the
    /// view can't render off a headless display). `cellW`/`cellH` are BACKING
    /// pixels; `cols`/`rows` are the HOST grid (from the REAL surface — NOT the
    /// mirror's own frame-tracking `surfaceSize`, which would feed back and
    /// collapse the view).
    ///
    /// `naturalW`×`naturalH` is the FULL host grid in points (the SurfaceWrapper
    /// frame, so every row renders with no internal clip/pad). `scale` is UNIFORM
    /// — chosen so `referenceColumns` columns span the container width — so text
    /// size is identical across tiles; `scaledW`×`scaledH` is the on-screen size
    /// after scaling (the horizontal-scroll content width is `scaledW`). Falls
    /// back to width-fit (scale so the whole grid fits) when the cell size isn't
    /// known yet, so the view never collapses.
    struct PreviewGeometry: Equatable {
        let naturalW: CGFloat
        let naturalH: CGFloat
        let scale: CGFloat
        let scaledW: CGFloat
        let scaledH: CGFloat
    }

    /// Remembered HOST grid geometry (see the body's `hostGeomBox`). All-zero means
    /// "never seen a valid host frame yet".
    struct HostGeom: Equatable {
        var cols: Int = 0
        var rows: Int = 0
        var cellW: CGFloat = 0
        var cellH: CGFloat = 0
    }
    /// Reference box so `body` can update the cache without mutating SwiftUI @State
    /// (mutating the object, not the binding — no invalidation). `fold` stores the
    /// merged result and returns it, so the call site is a `let` (a bare assignment
    /// is illegal inside a `@ViewBuilder`).
    final class HostGeomBox {
        var value = HostGeom()
        /// Latched-once fallback cell size for the host-never-seen (zoom-hidden-at-open)
        /// case — held stable so the mirror's own jittering `cell_width_px` can't
        /// oscillate the preview. Set on first non-zero read in `resolveGrid`, never
        /// re-written.
        var fallbackCellW: CGFloat = 0
        var fallbackCellH: CGFloat = 0
        func fold(hostCols: Int, hostRows: Int, hostCellW: CGFloat, hostCellH: CGFloat) -> HostGeom {
            value = AgentMirrorPreview.mergeHostGeom(
                prior: value, hostCols: hostCols, hostRows: hostRows,
                hostCellW: hostCellW, hostCellH: hostCellH)
            return value
        }
    }

    /// PURE: fold a live host-surface read into the remembered geometry. A VALID
    /// frame (cols>0 AND cellW>0) replaces the cache; an absent/zero read — which is
    /// what a split hidden under a sibling's zoom reports, since its `SurfaceView`
    /// left the hierarchy — KEEPS the prior value, because the host session's grid
    /// did not actually change. This is what stops a zoom-hidden tile from collapsing
    /// to cols=0 (the degenerate huge/flickering preview).
    static func mergeHostGeom(
        prior: HostGeom, hostCols: Int, hostRows: Int, hostCellW: CGFloat, hostCellH: CGFloat
    ) -> HostGeom {
        guard hostCols > 0, hostCellW > 0 else { return prior }
        return HostGeom(cols: hostCols, rows: hostRows, cellW: hostCellW, cellH: hostCellH)
    }

    static func geometry(
        cols: Int, rows: Int, cellW: CGFloat, cellH: CGFloat,
        backing: CGFloat, container: CGSize, referenceColumns: CGFloat = referenceColumns
    ) -> PreviewGeometry {
        let bk = backing > 0 ? backing : 2.0
        let naturalW = (cols > 0 && cellW > 0) ? CGFloat(cols) * cellW / bk : container.width
        let naturalH = (rows > 0 && cellH > 0) ? CGFloat(rows) * cellH / bk : container.height
        // UNIFORM scale: referenceColumns columns fill the container width, so
        // every tile renders at the same cell size. Before the first frame
        // (cellW == 0) fall back to width-fit so the view still fills the row.
        let scale: CGFloat
        if cellW > 0 && referenceColumns > 0 {
            scale = container.width / (referenceColumns * cellW / bk)
        } else if naturalW > 0 {
            scale = container.width / naturalW
        } else {
            scale = 1.0
        }
        return PreviewGeometry(
            naturalW: naturalW, naturalH: naturalH, scale: scale,
            scaledW: naturalW * scale, scaledH: naturalH * scale)
    }

    /// PURE: the vertical offset (points, DOWNWARD) to shift the bottom-anchored
    /// scaled mirror so the LAST row of content sits at the bottom of the
    /// preview, dropping `skipRows` trailing rows (blanks + footer) below the
    /// clip. Factored out for unit testing.
    ///
    /// Returns 0 when there's nothing to skip → identical to a plain bottom-
    /// anchor. Clamped to `rows - 1` so at least one row stays anchored, i.e. an
    /// all-blank screen shows a single row instead of scrolling the grid fully
    /// out of view. The per-row scaled height matches `geometry`'s:
    /// `(cellH / backing) * scale`.
    static func bottomAnchorOffset(
        skipRows: Int, rows: Int, cellH: CGFloat, backing: CGFloat, scale: CGFloat
    ) -> CGFloat {
        guard skipRows > 0, rows > 1, cellH > 0, scale > 0 else { return 0 }
        let bk = backing > 0 ? backing : 2.0
        let clamped = min(skipRows, rows - 1)
        let scaledRowH = (cellH / bk) * scale
        return CGFloat(clamped) * scaledRowH
    }

    // MARK: - Footer detection (skip information-less chrome)

    /// Caps for the footer heuristic. CONSERVATIVE — biased toward showing
    /// content.
    private static let maxStatusLines = 3   // mode/help lines below a box's bottom border
    private static let ruleMinDashes = 12   // a horizontal rule is a long ── run

    /// PURE: how many trailing viewport rows to drop from a bottom-anchored
    /// thumbnail so the LAST row of real content lands at the bottom. `rows` is
    /// the row-accurate viewport, top-first (under pty-host the GUI mirror is
    /// exactly one text line per grid row — no soft-wrap, blanks preserved).
    ///
    /// Drops trailing information-less chrome: blank rows, an agent input box or
    /// a content box's empty bottom (the `/workflows` viewer's empty cells +
    /// bottom border), and the mode/status/help line(s) beneath it — stopping at
    /// the first row with REAL content so nothing meaningful is hidden.
    ///
    /// Conservative gating (else only trailing blanks are skipped):
    ///   1. at most `maxStatusLines` status/help lines (plain text, NO box-drawing
    ///      — e.g. "⏵⏵ auto mode on…", "↑↓ select · x stop workflow…") sit above…
    ///   2. …a horizontal-rule row (a box's bottom border), and then
    ///   3. we peel the box's structural rows upward — borders (incl. one carrying
    ///      embedded status text, e.g. the claude-pool line), empty interior cells
    ///      (`│   │`), the empty `❯` prompt, and blank gap — stopping at the first
    ///      row with real content (a filled box-interior row, a question, output).
    static func chromeTrailingSkip(rows: [String]) -> Int {
        let n = rows.count
        if n == 0 { return 0 }

        // Trailing blank rows (the fallback skip when there's no chrome footer).
        var i = n - 1
        while i >= 0 && isBlankRow(rows[i]) { i -= 1 }
        if i < 0 { return n }                  // all blank
        let blanks = n - 1 - i
        let lastContent = i

        // 1. Peel up to `maxStatusLines` status/help lines (plain text, no
        //    box-drawing — distinguishes an outside-the-box status line from a
        //    filled box-interior row, which has `│` borders).
        var k = lastContent
        var status = 0
        while k >= 0 && isStatusLine(rows[k]) && status < maxStatusLines {
            k -= 1
            status += 1
        }

        // 2. The chrome MUST bottom out in a horizontal rule (a box's bottom
        //    border). If not, this isn't a box footer → skip only trailing blanks.
        guard k >= 0, isRuleRow(rows[k]) else { return blanks }

        // 3. Peel structural rows upward — rules (incl. text-embedded borders) and
        //    empty-ish interior/blank rows — stopping at the first real-content row.
        while k >= 0 && (isRuleRow(rows[k]) || isEmptyInteriorRow(rows[k])) { k -= 1 }
        return n - 1 - k
    }

    /// A status/help line: real text with NO box-drawing characters (e.g.
    /// "⏵⏵ auto mode on (shift+tab to cycle)", "↑↓ select · x stop workflow…").
    /// The no-box-drawing test is what separates it from a filled box-interior
    /// row (which carries `│` borders), so a box's content rows are never peeled
    /// as "status".
    static func isStatusLine(_ s: String) -> Bool {
        if isEmptyInteriorRow(s) { return false }   // blank / border / empty interior
        for u in s.unicodeScalars where (0x2500...0x257F).contains(u.value) { return false }
        return true
    }

    /// A blank row: empty or whitespace-only. Uses the Unicode whitespace
    /// property so NO-BREAK SPACE (U+00A0) and friends count — Claude Code pads
    /// with U+00A0, not U+0020.
    static func isBlankRow(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    /// A horizontal-rule row: a long run of box-drawing horizontal line chars
    /// (`─`, U+2500) — the input box's top/bottom border (full-width rule or a
    /// rounded `╭──╮`/`╰──╯` border). `─` is essentially never in plain content,
    /// so this is a clean signal.
    static func isRuleRow(_ s: String) -> Bool {
        var dashes = 0
        for u in s.unicodeScalars where u.value == 0x2500 { dashes += 1 }
        return dashes >= ruleMinDashes
    }

    /// An empty-ish input-box interior row: nothing but the prompt marker
    /// (`❯`/`>`), box-drawing borders (`│` etc.), and whitespace. Real typed
    /// text or a permission question makes it non-empty → the box is shown.
    static func isEmptyInteriorRow(_ s: String) -> Bool {
        for u in s.unicodeScalars {
            // Unicode whitespace covers space/tab AND U+00A0 NO-BREAK SPACE,
            // which Claude Code uses to pad the prompt line (`❯\u{00A0}…`). The
            // old 0x20/0x09-only check read that NBSP as content and never
            // skipped the footer — the bug behind "nothing changed".
            if u.properties.isWhitespace { continue }
            if u.value == 0x276F || u.value == 0x3E { continue }        // ❯  >
            if (0x2500...0x257F).contains(u.value) { continue }         // box drawing
            return false
        }
        return true
    }

    // MARK: - Background-shell detection (ramon fork / Agent hooks)

    /// How many trailing rows to scan for Claude Code's background-shell footer
    /// indicator. The indicator always lives in the bottom status line(s), so a
    /// small window both bounds the cost and keeps false positives out of the
    /// scrollback content above the footer.
    private static let bgShellScanRows = 8

    /// PURE: the number of BACKGROUND SHELLS Claude Code reports as still running,
    /// read from its bottom status line — `0` when none. Used to DEMOTE a tile
    /// that the hook reports as `.waiting`: an agent that has finished its turn but
    /// still has a background shell churning is waiting on its OWN work, not on the
    /// user, so it must not nag (see `AgentDashboardModel.needsAttention` /
    /// `applyAgentState`).
    ///
    /// Claude Code renders the count in its footer in two shapes, both of which we
    /// match (a digit run immediately before the word "shell"):
    ///   - idle / auto mode:  `⏵⏵ auto mode on · 1 shell · ← for age…`
    ///   - processing:        `✻ Crunched for 1m 48s · 1 shell still running`
    ///
    /// We only consider STATUS lines (real text, no box-drawing — same test the
    /// footer skip uses), so a `│ … shell … │` box-interior content row is never
    /// mistaken for the indicator. `rows` is the row-accurate viewport (top-first).
    static func backgroundShellCount(rows: [String]) -> Int {
        let start = max(0, rows.count - bgShellScanRows)
        var count = 0
        for row in rows[start...] where isStatusLine(row) {
            if let n = shellCount(inStatusLine: row) { count = max(count, n) }
        }
        return count
    }

    /// PURE: extract `N` from a `… N shell[s] …` status line, or nil if the line
    /// carries no `<digits> shell` token. A single space between the number and
    /// "shell" is tolerated (the `· 1 shell ·` form); a non-digit/non-space char
    /// before "shell" (e.g. a letter, as in "myshell") yields no count.
    static func shellCount(inStatusLine s: String) -> Int? {
        let chars = Array(s)
        let needle = Array("shell")
        var best: Int? = nil
        var i = 0
        while i + needle.count <= chars.count {
            if Array(chars[i ..< i + needle.count]) == needle {
                var j = i - 1
                if j >= 0 && chars[j] == " " { j -= 1 }   // tolerate one space
                var digits = ""
                while j >= 0, chars[j].isNumber {
                    digits = String(chars[j]) + digits
                    j -= 1
                }
                if let n = Int(digits) { best = max(best ?? 0, n) }
            }
            i += 1
        }
        return best
    }
}
