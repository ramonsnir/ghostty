import SwiftUI

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

    /// (ramon fork / Agent hooks) Whether the tile is demanding attention: a
    /// bell rang OR the hook reports the agent is `.waiting` for the user. Both
    /// are independent inputs — either lights the amber border + "needs input"
    /// pill (mirrors the model's attention-first sort). NOTE the waiting
    /// auto-unhide is weaker than the bell's: it fires only on the enters-waiting
    /// edge (a Notification is single-shot), not on every republish, so unlike a
    /// still-ringing tile a still-waiting tile CAN be re-hidden — see
    /// `AgentDashboardModel.applyAgentState`.
    private var needsAttention: Bool {
        entry.bell || entry.agentState == .waiting
    }

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
                    needsAttention ? Self.bellAmber : (hovering ? Color.accentColor.opacity(0.6) : Color.clear),
                    lineWidth: needsAttention ? 3 : 1
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
            if needsAttention {
                // Attention affordance: a bell rang OR the hook reports waiting.
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
        if previewsEnabled, entry.sessionID != 0, ghostty.app != nil {
            AgentMirrorPreview(ghostty: ghostty, sessionID: entry.sessionID)
                .allowsHitTesting(false)
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
            if needsAttention {
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

/// (ramon fork / Agent Dashboard, Layer 3) The embedded read-only mirror. Builds
/// a `Ghostty.SurfaceView` with `mirror = true` + the host session id, then lets
/// the existing SurfaceWrapper render it natively (full color, viewport-only —
/// exactly right for a thumbnail).
///
/// Scaling (spec §2.2): the mirror renders at the HOST's authoritative grid
/// (cols×rows); we never drive a resize toward it (it's read-only and the core
/// suppresses outbound resize). Instead we DISPLAY it scaled — aspect-fit by
/// WIDTH and anchored to the BOTTOM via `scaleEffect(_:anchor:.bottom)`, so the
/// agent's LATEST rows stay visible and the top is clipped. The SurfaceWrapper
/// is given the mirror's own pixel size as its frame so SwiftUI's letterboxing
/// is a no-op and our scaleEffect is the only transform. Hit-testing is disabled
/// at the call site so the CARD (not the mirror) receives the click.
struct AgentMirrorPreview: View {
    /// Injected into the SurfaceWrapper's `@EnvironmentObject` — without this the
    /// wrapper traps ("No ObservableObject of type App found") the moment a live
    /// preview mounts. Every other SurfaceWrapper mount injects it.
    let ghostty: Ghostty.App
    let sessionID: UInt64

    @StateObject private var surfaceView: Ghostty.SurfaceView

    init(ghostty: Ghostty.App, sessionID: UInt64) {
        self.ghostty = ghostty
        self.sessionID = sessionID
        var cfg = Ghostty.SurfaceConfiguration()
        cfg.mirror = true
        cfg.sessionID = String(sessionID)
        _surfaceView = StateObject(wrappedValue: Ghostty.SurfaceView(ghostty.app!, baseConfig: cfg))
    }

    var body: some View {
        GeometryReader { geo in
            // The mirror's authoritative pixel size (host grid). Until the first
            // frame lands `surfaceSize` is nil; fall back to the container size so
            // the scale is a no-op (1.0) rather than collapsing the view.
            let mirrorW = surfaceView.surfaceSize.map { CGFloat($0.width_px) } ?? geo.size.width
            let mirrorH = surfaceView.surfaceSize.map { CGFloat($0.height_px) } ?? geo.size.height
            // Aspect-fit by WIDTH: the preview width drives the scale so long
            // lines / TUI layouts read at full width; the bottom anchor keeps the
            // most-recent rows pinned and clips the top.
            let scale = (mirrorW > 0) ? (geo.size.width / mirrorW) : 1.0

            Ghostty.SurfaceWrapper(surfaceView: surfaceView, isSplit: true)
                .environmentObject(ghostty)
                .frame(width: mirrorW, height: mirrorH)
                .scaleEffect(scale, anchor: .bottom)
                // Pin the scaled view to the bottom of the container so the
                // top overflow is what gets clipped (.clipped() is applied at
                // the call site).
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }
}
