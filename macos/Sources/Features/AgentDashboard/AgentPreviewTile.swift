import SwiftUI
import AppKit

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
                    entry.bell ? Self.bellAmber : (hovering ? Color.accentColor.opacity(0.6) : Color.clear),
                    lineWidth: entry.bell ? 3 : 1
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
            Text(entry.title.isEmpty ? "(untitled)" : entry.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if entry.bell {
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

    private var footer: some View {
        HStack(spacing: 6) {
            Text((entry.pwd as NSString).lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            if entry.bell {
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
/// Scaling: the mirror renders the HOST's authoritative grid (cols×rows) at a
/// FIXED cell size — it does NOT scale the font to fit the view, it draws the
/// cells top-aligned and clips/pads the remainder. So if we framed it at the
/// (short) container height the surface would clip its OWN BOTTOM rows — exactly
/// the latest output we want to keep. Instead we frame the SurfaceWrapper at the
/// grid's NATURAL size (`columns·cell_width_px × rows·cell_height_px`, converted
/// to points via the backing scale) so EVERY row renders with no internal
/// clip/pad, THEN DISPLAY it scaled — aspect-fit by WIDTH and anchored to the
/// BOTTOM via `scaleEffect(_:anchor:.bottom)` — so the agent's LATEST rows stay
/// pinned to the bottom and the TOP overflow is clipped at the call site.
/// Hit-testing is disabled at the call site so the CARD (not the mirror)
/// receives the click.
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
            // The grid's NATURAL render size in POINTS. `columns`/`rows` are the
            // host's authoritative grid and `cell_*_px` are BACKING pixels, so we
            // divide by the backing scale to get points. Framing the surface at
            // exactly this size means the framebuffer equals the grid's natural
            // size: every row renders, with no internal top-align clip (which was
            // eating the latest rows) and no bottom padding. Until the first frame
            // lands `surfaceSize` is nil; fall back to the container so the scale
            // is a no-op (1.0) rather than collapsing the view.
            let backing = surfaceView.window?.backingScaleFactor
                ?? NSScreen.main?.backingScaleFactor ?? 2.0
            let naturalW = surfaceView.surfaceSize.map {
                CGFloat($0.columns) * CGFloat($0.cell_width_px) / backing
            } ?? geo.size.width
            let naturalH = surfaceView.surfaceSize.map {
                CGFloat($0.rows) * CGFloat($0.cell_height_px) / backing
            } ?? geo.size.height
            // Aspect-fit by WIDTH: the preview width drives the scale so long
            // lines / TUI layouts read at full width; the bottom anchor keeps the
            // most-recent rows pinned and clips the top.
            let scale = (naturalW > 0) ? (geo.size.width / naturalW) : 1.0

            Ghostty.SurfaceWrapper(surfaceView: surfaceView, isSplit: true)
                .environmentObject(ghostty)
                .frame(width: naturalW, height: naturalH)
                .scaleEffect(scale, anchor: .bottom)
                // Pin the scaled view to the bottom of the container so the
                // top overflow is what gets clipped (.clipped() is applied at
                // the call site).
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }
}
