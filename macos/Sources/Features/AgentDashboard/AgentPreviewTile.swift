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
        if previewsEnabled, entry.sessionID != 0, ghostty.app != nil, let realView = entry.realView {
            AgentMirrorPreview(ghostty: ghostty, sessionID: entry.sessionID, realSurface: realView)
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

            Ghostty.SurfaceWrapper(surfaceView: surfaceView, isSplit: true)
                .environmentObject(ghostty)
                .frame(width: g.naturalW, height: g.naturalH)
                .scaleEffect(g.scale, anchor: .bottom)
                // Pin the scaled view to the bottom of the container so the top
                // overflow is what gets clipped (.clipped() at the call site).
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
    }

    /// PURE geometry for the mirror preview, factored out for unit testing (the
    /// view can't render off a headless display). `cellW`/`cellH` are BACKING
    /// pixels; `cols`/`rows` are the HOST grid. Returns the SurfaceWrapper frame
    /// (the full host grid drawn at the mirror's cell size, so every row renders
    /// with no internal clip/pad — `naturalW`×`naturalH` in points) and the
    /// width-fit `scale` applied bottom-anchored. Falls back to the container
    /// size (scale 1) when the grid/cell is not yet known, so the view never
    /// collapses. Using the FULL grid size here — not the mirror's own
    /// frame-tracking `surfaceSize` — is what prevents the feedback collapse that
    /// made the preview go empty / show one row.
    struct PreviewGeometry: Equatable {
        let naturalW: CGFloat
        let naturalH: CGFloat
        let scale: CGFloat
    }
    static func geometry(
        cols: Int, rows: Int, cellW: CGFloat, cellH: CGFloat,
        backing: CGFloat, container: CGSize
    ) -> PreviewGeometry {
        let bk = backing > 0 ? backing : 2.0
        let naturalW = (cols > 0 && cellW > 0) ? CGFloat(cols) * cellW / bk : container.width
        let naturalH = (rows > 0 && cellH > 0) ? CGFloat(rows) * cellH / bk : container.height
        let scale = naturalW > 0 ? container.width / naturalW : 1.0
        return PreviewGeometry(naturalW: naturalW, naturalH: naturalH, scale: scale)
    }
}
