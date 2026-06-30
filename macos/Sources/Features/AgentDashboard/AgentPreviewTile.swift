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
    let onHide: () -> Void
    /// Force-close this split + free its (queue) slot — the escape hatch for a wedged
    /// queue agent. Gated behind a confirmation (no undo: it ends the agent).
    let onClose: () -> Void
    /// (keep) Toggle this queue split's KEEP state — exempt it from the queue's auto-close so
    /// you can do manual work after the task is done (or un-keep it). The argument is the
    /// DESIRED new value (true = keep, false = allow auto-close). Queue tiles only.
    let onKeep: (Bool) -> Void

    @State private var hovering = false
    @State private var confirmClose = false

    /// The fork's bell amber (matches the in-terminal bell border).
    private static let bellAmber = Color(red: 1.0, green: 0.8, blue: 0.0)

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
                .strokeBorder(
                    bellRinging ? Self.bellAmber : (hovering ? Color.accentColor.opacity(0.6) : Color.clear),
                    lineWidth: bellRinging ? 3 : 1
                )
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
            if bellRinging {
                // REAL-bell affordance only. Clears on focus (bell-tied); the hook
                // `.waiting` status uses the "waiting ⚠" chip + "needs input" pill
                // instead, which persist.
                Image(systemName: "bell.badge.fill")
                    .font(.caption2)
                    .foregroundStyle(Self.bellAmber)
            }
            // (keep) The 📌 pin toggle — queue tiles only. Shown PERSISTENTLY when kept (so
            // a pinned split is obvious without hovering) and on hover otherwise. Filled +
            // accent when kept; outline + secondary when not. Clicking flips the keep state
            // (optimistic; the supervisor's set_keep confirms it). It's the "exempt this
            // split from auto-close so I can keep working" control.
            if isQueueOwned && (isKept || hovering) {
                Button { onKeep(!isKept) } label: {
                    Image(systemName: isKept ? "pin.fill" : "pin")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isKept ? Color.accentColor : Color.secondary)
                .help(isKept
                    ? "Kept — the queue won't auto-close this split. Click to allow auto-close."
                    : "Keep this split open (exempt it from the queue's auto-close so you can do manual work).")
            }
            if hovering {
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
                    .help("Close this split (ends the agent; frees its queue slot)")
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
                .help("Hide this tile (declutter — the split keeps running and re-surfaces on a bell)")
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
                .help("Queue: \(name)" + (key.map { " · \($0)" } ?? ""))
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
            AgentMirrorPreview(ghostty: ghostty, sessionID: entry.sessionID, realSurface: realView)
                .frame(maxWidth: .infinity)
                .frame(height: Self.previewHeight)
                // Fill the whole preview rectangle with the THEME terminal
                // background so any area the bottom-anchored mirror doesn't cover
                // (e.g. vertical slack when a short pane's scaled height is under the
                // fixed preview height) blends seamlessly into the mirror instead of
                // showing the tile's control-background. Read from config (the
                // `background` color), never hard-coded; the mirror surface paints
                // the same color under its cells, so the seam is invisible.
                .background(ghostty.config.backgroundColor)
                .clipped()
                // (ramon fork / Agent Manager) The Haiku summary, shown LARGE +
                // semi-transparent over the TOP of the live preview so it's readable
                // at a glance, and FADED OUT on hover to reveal the terminal beneath.
                .overlay(alignment: .top) { summaryOverlay }
                // Re-create the mirror SurfaceView if the session id changes for a
                // stable tile id (the @StateObject is otherwise keyed only by the
                // ForEach UUID, so it would keep the old session).
                .id(entry.sessionID)
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

    /// Number of trailing rows to drop below the bottom-anchored thumbnail —
    /// empty rows PLUS an information-less footer (the agent's input box + its
    /// mode/status lines) — so the preview rises to the last row of actual
    /// CONTENT. Computed by `chromeTrailingSkip` from the real surface's viewport
    /// text, polled on a light timer (live frames render off the Metal path, not
    /// SwiftUI, so an observer wouldn't fire).
    @State private var skipRows: Int = 0

    init(ghostty: Ghostty.App, sessionID: UInt64, realSurface: Ghostty.SurfaceView) {
        self.ghostty = ghostty
        self.sessionID = sessionID
        self.realSurface = realSurface
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.mirror = true
        cfg.sessionID = String(sessionID)
        _surfaceView = StateObject(wrappedValue: Ghostty.SurfaceView(ghostty.app!, baseConfig: cfg))
    }

    var body: some View {
        GeometryReader { geo in
            let backing = surfaceView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2.0
            // HOST grid from the real surface (authoritative; the mirror's own
            // grid AND cell size track our frame and must not be used — see below).
            let host = realSurface.surfaceSize
            let rows = Int(host?.rows ?? 0)
            // Per-cell pixels come from the HOST (real) surface FIRST, the mirror
            // only as a fallback — the SAME source as cols/rows. This is
            // LOAD-BEARING (not a style choice): the mirror's frame is computed
            // from this cell size, and the mirror's OWN `cell_width_px` jitters by
            // ±1px (e.g. 17↔16) as that frame re-rounds its framebuffer onto a
            // sub-pixel boundary — so reading it here closes a feedback loop that
            // oscillates the scale every frame (a ~160 Hz "font size flicker",
            // display-dependent because the rounding sits on a half-pixel edge).
            // The host surface has a fixed real frame, so its cell size is stable
            // and breaks the loop. (Was: mirror-first, the flicker bug.)
            let cellH = CGFloat(host?.cell_height_px ?? surfaceView.surfaceSize?.cell_height_px ?? 0)
            let g = AgentMirrorPreview.geometry(
                cols: Int(host?.columns ?? 0),
                rows: rows,
                cellW: CGFloat(host?.cell_width_px ?? surfaceView.surfaceSize?.cell_width_px ?? 0),
                cellH: cellH,
                backing: backing,
                container: geo.size)
            // Skip empty trailing rows + the input-box/mode-line footer: shift
            // the bottom-anchored mirror down so the last row of CONTENT lands at
            // the bottom of the preview (the skipped rows fall below the clip).
            // 0 for a full screen with no detectable footer → unchanged.
            let anchorOffset = AgentMirrorPreview.bottomAnchorOffset(
                skipRows: skipRows, rows: rows,
                cellH: cellH, backing: backing, scale: g.scale)

            // FIT-TO-WIDTH: the mirror is scaled (g.scale) so the agent pane's own
            // width fills the tile, so `scaledW == geo.width` and there's no
            // horizontal overflow — the ScrollView is retained only as a stable
            // container (indicators off; it never actually scrolls). `.bottomLeading`
            // pins column 0 + the agent's latest (bottom) rows; the top is clipped.
            ScrollView(.horizontal, showsIndicators: false) {
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
                        while !Task.isCancelled {
                            refreshSkipRows()
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

    /// PURE geometry for the mirror preview, factored out for unit testing (the
    /// view can't render off a headless display). `cellW`/`cellH` are BACKING
    /// pixels; `cols`/`rows` are the HOST grid (from the REAL surface — NOT the
    /// mirror's own frame-tracking `surfaceSize`, which would feed back and
    /// collapse the view; see the body's host-first cell-size reads).
    ///
    /// `naturalW`×`naturalH` is the FULL host grid in points (the SurfaceWrapper
    /// frame, so every row renders with no internal clip/pad). **FIT-TO-WIDTH:**
    /// `scale` makes the agent pane's OWN width fill the tile, so every preview
    /// uses the whole width regardless of the pane's column count — a narrow split
    /// scales UP, a wide one DOWN; the caller bottom-anchors + height-clips to show
    /// the latest rows. `scaledW` therefore equals the container width (no
    /// horizontal overflow / scroll). The backing factor cancels out of
    /// `scaledW`/`scaledH`, so the on-screen result is independent of any
    /// backing-scale mismatch. Falls back to the container size when the grid/cell
    /// isn't known yet, so the view never collapses.
    ///
    /// (Was: a fixed 125-column reference + uniform scale, which left narrower panes
    /// using only `cols/125` of the tile width — e.g. ~⅓ for a ~40-col split — and
    /// just rescaled that fraction on a dashboard resize instead of reflowing.)
    struct PreviewGeometry: Equatable {
        let naturalW: CGFloat
        let naturalH: CGFloat
        let scale: CGFloat
        let scaledW: CGFloat
        let scaledH: CGFloat
    }
    static func geometry(
        cols: Int, rows: Int, cellW: CGFloat, cellH: CGFloat,
        backing: CGFloat, container: CGSize
    ) -> PreviewGeometry {
        let bk = backing > 0 ? backing : 2.0
        let naturalW = (cols > 0 && cellW > 0) ? CGFloat(cols) * cellW / bk : container.width
        let naturalH = (rows > 0 && cellH > 0) ? CGFloat(rows) * cellH / bk : container.height
        // FIT-TO-WIDTH: scale the agent pane's own width to fill the tile width.
        // scaledW == container.width for any column count (narrow → up, wide → down).
        let scale = naturalW > 0 ? container.width / naturalW : 1.0
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
