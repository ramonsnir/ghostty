import SwiftUI
import AppKit
import GhosttyKit

/// (ramon fork / Agent Dashboard, Layer 3) One row: a full-width card with a
/// compact header (badge · title · bell dot · hide ✕), a live (or metadata-only)
/// preview showing the agent's LATEST rows, and a dim footer. READ-ONLY:
/// clicking the card jumps to the real split (present + unzoom). No inline reply
/// / key forwarding (LOCKED #3).
struct AgentPreviewTile: View {
    let entry: AgentEntry
    let ghostty: Ghostty.App
    /// When false (pty-host off), render a metadata-only tile (no mirror).
    let previewsEnabled: Bool
    let onHide: () -> Void

    @State private var hovering = false

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
    private var bellRinging: Bool { entry.bell }
    private var waitingForInput: Bool { entry.agentState == .waiting }

    /// Fixed height of the preview area. Kept deliberately SHORTER than a
    /// full-width terminal scales to, so the bottom-anchored mirror clips the
    /// top and the agent's most-recent rows ("latest progress") stay visible
    /// (request #3).
    private static let previewHeight: CGFloat = 220

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
        .onTapGesture { jump() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Jump to \(entry.agent?.command ?? "agent") — \(entry.title)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            badge
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
            if hovering {
                Button(action: onHide) {
                    Image(systemName: "xmark")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Hide this agent")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    private var badge: some View {
        Text(entry.agent?.command ?? "•")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.secondary.opacity(0.18))
            .clipShape(Capsule())
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
            chip("waiting ⚠", fg: Self.bellAmber, bg: Self.bellAmber.opacity(0.2))
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
                .clipped()
                // Re-create the mirror SurfaceView if the session id changes for a
                // stable tile id (the @StateObject is otherwise keyed only by the
                // ForEach UUID, so it would keep the old session).
                .id(entry.sessionID)
        } else {
            ZStack {
                Color.black.opacity(0.04)
                Text("Preview unavailable")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: Self.previewHeight)
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        // (ramon fork / Agent hooks) Optional prompt subtitle (truncated) above
        // the metadata row, so a `working` agent shows what it was asked. Gated on
        // `.working` (like the `⛭ tool` footer below) so a finished/idle or
        // waiting tile stays visually quiet rather than keeping the stale prompt.
        if entry.agentState == .working, let prompt = entry.lastPrompt, !prompt.isEmpty {
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
            if waitingForInput {
                // Hook-driven status: persists until the agent reports a new state
                // (NOT cleared by focus, unlike the bell frame/icon).
                pill("needs input", color: Self.bellAmber)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 16)
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
            // grid tracks our frame and must not be used). Per-cell pixels come
            // from the mirror (font metrics, stable), falling back to the real
            // surface's cell.
            let host = realSurface.surfaceSize
            let g = AgentMirrorPreview.geometry(
                cols: Int(host?.columns ?? 0),
                rows: Int(host?.rows ?? 0),
                cellW: CGFloat(surfaceView.surfaceSize?.cell_width_px ?? host?.cell_width_px ?? 0),
                cellH: CGFloat(surfaceView.surfaceSize?.cell_height_px ?? host?.cell_height_px ?? 0),
                backing: backing,
                container: geo.size)

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
                    }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
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
}
