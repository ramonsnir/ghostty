// (ramon fork / Agent Queue, backlog graph) The dependency-graph CANVAS opened from the
// dashboard's "N backlog" header button. Renders a run's WHOLE board (the optional
// `provider.graph` push, stored on the model as `queueGraphs[runName]`) as a left→right
// layered DAG: columns by dependency depth, arrows for "blocked by", node cards colored by
// workflow-state category with label chips, and a green ring on items currently running in
// the queue. Clicking a node jumps to its live split (if running) or opens its tracker URL.
//
// The LAYOUT is a pure, unit-tested function (`QueueBacklogLayout.assignLayers`); the view +
// the NSWindow host are GUI-only. macOS-only (iOS-excluded like the rest of the feature).

import AppKit
import SwiftUI

// MARK: - Pure layout (unit-tested in AgentDashboardTests)

/// Pure DAG layout helpers for the backlog canvas. Kept free of SwiftUI/AppKit so the
/// layering algorithm is unit-testable.
enum QueueBacklogLayout {
    /// Assign each node a LAYER (column) index by longest-path-from-roots over the
    /// `blockedBy` edges: a node with no in-set blockers is layer 0; otherwise it is
    /// `1 + max(layer(blocker))`. So blockers sit to the LEFT of what they block, and an
    /// arrow blocker→blocked always points rightward.
    ///
    /// CYCLE-SAFE: a `blockedBy` cycle (which a tracker shouldn't produce but could) is
    /// broken by ignoring back-edges into a node currently being resolved — the node still
    /// gets a finite layer rather than looping forever. Edges to keys NOT in the node set
    /// (a blocker outside the run's scope) are ignored. PURE.
    static func assignLayers(_ nodes: [QueueGraph.Node]) -> [String: Int] {
        let present = Set(nodes.map(\.key))
        let blockersByKey: [String: [String]] = Dictionary(
            uniqueKeysWithValues: nodes.map { node in
                (node.key, node.blockedBy.filter { present.contains($0) && $0 != node.key })
            })

        var layer: [String: Int] = [:]
        var resolving: Set<String> = []

        func depth(_ key: String) -> Int {
            if let cached = layer[key] { return cached }
            // Re-entry on a key still being resolved ⇒ a cycle; treat as a root for the
            // back-edge (don't recurse into it again) so resolution always terminates.
            if resolving.contains(key) { return 0 }
            resolving.insert(key)
            var d = 0
            for blocker in blockersByKey[key] ?? [] {
                d = max(d, depth(blocker) + 1)
            }
            resolving.remove(key)
            layer[key] = d
            return d
        }

        for node in nodes { _ = depth(node.key) }
        return layer
    }

    /// Group nodes into ordered COLUMNS by layer (column 0 = roots). Within a column the
    /// input order is preserved (stable). PURE.
    static func columns(_ nodes: [QueueGraph.Node]) -> [[QueueGraph.Node]] {
        let layers = assignLayers(nodes)
        guard let maxLayer = layers.values.max() else { return [] }
        var cols: [[QueueGraph.Node]] = Array(repeating: [], count: maxLayer + 1)
        for node in nodes { cols[layers[node.key] ?? 0].append(node) }
        return cols
    }
}

// MARK: - Geometry (shared by the view + the window-default sizing; pure, unit-tested)

/// Card + spacing geometry for the canvas (points), plus the PURE size computations the
/// view's layout and the window's default-size both use — so the window opens just big
/// enough to show the whole board (the window manager clamps to the display).
enum QueueBacklogGeometry {
    static let cardW: CGFloat = 168
    static let cardH: CGFloat = 70
    static let hGap: CGFloat = 56     // gap to the right of each column
    static let vGap: CGFloat = 18     // gap below each row
    static let pad: CGFloat = 24      // padding around the board inside the scroll view
    static let headerHeight: CGFloat = 44  // the title/legend bar above the board

    /// The board (ZStack) content size for a set of columns: width = columns × (card+gap),
    /// height = tallest column × (card+gap). Floored at one card so an empty board isn't 0.
    static func boardSize(_ columns: [[QueueGraph.Node]]) -> CGSize {
        let rows = columns.map(\.count).max() ?? 0
        let w = CGFloat(columns.count) * (cardW + hGap)
        let h = CGFloat(rows) * (cardH + vGap)
        return CGSize(width: max(w, cardW), height: max(h, cardH))
    }

    /// The PREFERRED window CONTENT size to show the whole board without scrolling — the
    /// board plus its surrounding padding plus the header bar. The window manager clamps
    /// this to the display. PURE (unit-tested).
    static func preferredWindowSize(_ nodes: [QueueGraph.Node]) -> CGSize {
        let board = boardSize(QueueBacklogLayout.columns(nodes))
        return CGSize(width: board.width + pad * 2,
                      height: board.height + pad * 2 + headerHeight)
    }
}

// MARK: - Canvas view

/// The dependency-graph canvas for one queue run. Observes the model so it live-updates as
/// the sidecar re-pushes the board (≈ once per `listMs`) and as run status changes.
struct QueueBacklogCanvas: View {
    @ObservedObject var model: AgentDashboardModel
    let runName: String
    /// Jump to a live split for a node key (running items) — resolved + presented by the host.
    let onJumpToKey: (String) -> Void

    // Card + spacing geometry (points), from the shared QueueBacklogGeometry.
    private let cardW = QueueBacklogGeometry.cardW
    private let cardH = QueueBacklogGeometry.cardH
    private let hGap = QueueBacklogGeometry.hGap
    private let vGap = QueueBacklogGeometry.vGap
    private let pad = QueueBacklogGeometry.pad

    private var graph: QueueGraph? { model.queueGraphs[runName] }

    /// Keys currently RUNNING in the queue (from the health status) — highlighted on the canvas.
    private var runningKeys: Set<String> {
        Set(model.queueStatuses[runName]?.running.map(\.key) ?? [])
    }
    /// Keys currently WAITING (actionable) — a subtle highlight distinct from running.
    private var waitingKeys: Set<String> {
        Set(model.queueStatuses[runName]?.next.map(\.key) ?? [])
    }

    var body: some View {
        Group {
            if let graph, !graph.nodes.isEmpty {
                board(graph)
            } else if graph != nil {
                placeholder("This board is empty.", "No items in scope right now.")
            } else {
                placeholder("No backlog data.", "The run isn't reporting a board (provider.graph off, or it just ended).")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func placeholder(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func board(_ graph: QueueGraph) -> some View {
        let cols = QueueBacklogLayout.columns(graph.nodes)
        let centers = centersByKey(cols)
        let size = canvasSize(cols)
        VStack(alignment: .leading, spacing: 0) {
            header(graph)
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    // Edges UNDER the cards.
                    EdgeLayer(nodes: graph.nodes, centers: centers, cardW: cardW)
                        .frame(width: size.width, height: size.height)
                    ForEach(graph.nodes) { node in
                        if let c = centers[node.key] {
                            NodeCard(
                                node: node,
                                running: runningKeys.contains(node.key),
                                waiting: waitingKeys.contains(node.key)
                            )
                            .frame(width: cardW, height: cardH)
                            .position(x: c.x, y: c.y)
                            .onTapGesture { activate(node) }
                        }
                    }
                }
                .frame(width: size.width, height: size.height)
                .padding(pad)
            }
        }
    }

    @ViewBuilder
    private func header(_ graph: QueueGraph) -> some View {
        HStack(spacing: 8) {
            Text(runName).font(.headline).lineLimit(1).truncationMode(.middle)
            Text("\(graph.backlog) backlog")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.18))
                .clipShape(Capsule())
            Text("\(graph.nodes.count) total")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            LegendView()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
    }

    /// Tap → jump to the running split if we have one; else open the tracker URL.
    private func activate(_ node: QueueGraph.Node) {
        if runningKeys.contains(node.key) {
            onJumpToKey(node.key)
            return
        }
        if let url = node.url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    // MARK: layout → points

    private func centersByKey(_ cols: [[QueueGraph.Node]]) -> [String: CGPoint] {
        var out: [String: CGPoint] = [:]
        for (ci, col) in cols.enumerated() {
            let x = pad + CGFloat(ci) * (cardW + hGap) + cardW / 2
            for (ri, node) in col.enumerated() {
                let y = pad + CGFloat(ri) * (cardH + vGap) + cardH / 2
                out[node.key] = CGPoint(x: x, y: y)
            }
        }
        return out
    }

    private func canvasSize(_ cols: [[QueueGraph.Node]]) -> CGSize {
        QueueBacklogGeometry.boardSize(cols)
    }
}

// MARK: - Edges

/// Draws the "blocked by" edges (blocker → blocked) as arrows, under the cards.
private struct EdgeLayer: View {
    let nodes: [QueueGraph.Node]
    let centers: [String: CGPoint]
    let cardW: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            for node in nodes {
                guard let to = centers[node.key] else { continue }
                for blocker in node.blockedBy {
                    guard let from = centers[blocker] else { continue } // ignore dangling
                    // Exit the blocker's right edge, enter the blocked node's left edge.
                    let start = CGPoint(x: from.x + cardW / 2, y: from.y)
                    let end = CGPoint(x: to.x - cardW / 2, y: to.y)
                    var path = Path()
                    path.move(to: start)
                    // A gentle horizontal cubic so crossings read clearly.
                    let midX = (start.x + end.x) / 2
                    path.addCurve(
                        to: end,
                        control1: CGPoint(x: midX, y: start.y),
                        control2: CGPoint(x: midX, y: end.y))
                    ctx.stroke(path, with: .color(.secondary.opacity(0.55)), lineWidth: 1.5)
                    ctx.fill(arrowhead(at: end, from: CGPoint(x: midX, y: end.y)),
                             with: .color(.secondary.opacity(0.7)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// A small triangle pointing into `tip`, oriented along (tip − tail).
    private func arrowhead(at tip: CGPoint, from tail: CGPoint) -> Path {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let len: CGFloat = 8, spread: CGFloat = 0.5
        let p1 = CGPoint(x: tip.x - len * cos(angle - spread), y: tip.y - len * sin(angle - spread))
        let p2 = CGPoint(x: tip.x - len * cos(angle + spread), y: tip.y - len * sin(angle + spread))
        var path = Path()
        path.move(to: tip); path.addLine(to: p1); path.addLine(to: p2); path.closeSubpath()
        return path
    }
}

// MARK: - Node card

private struct NodeCard: View {
    let node: QueueGraph.Node
    let running: Bool
    let waiting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(node.key).font(.caption.weight(.bold)).lineLimit(1)
                if running {
                    Image(systemName: "play.circle.fill").font(.caption2).foregroundStyle(.green)
                } else if waiting {
                    Image(systemName: "clock").font(.caption2).foregroundStyle(.orange)
                }
                Spacer(minLength: 0)
            }
            if let title = node.title {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.tail)
            }
            if !node.labels.isEmpty {
                HStack(spacing: 3) {
                    ForEach(node.labels.prefix(3), id: \.self) { label in
                        Text(label).font(.system(size: 8)).lineLimit(1)
                            .padding(.horizontal, 3).padding(.vertical, 1)
                            .background(Color.purple.opacity(0.18))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(stateColor.opacity(node.done ? 0.07 : 0.16))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(borderColor, lineWidth: running ? 2 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(node.done ? 0.55 : 1.0)
        .help(node.state.map { "\(node.key) — \($0)" } ?? node.key)
    }

    private var borderColor: Color {
        if running { return .green }
        return stateColor.opacity(0.6)
    }

    /// Map the coarse workflow-state category to a color; unknown / nil → neutral.
    private var stateColor: Color { QueueBacklogColors.color(forStateType: node.stateType) }
}

/// Pure category→color map (shared so a test could assert it stays total).
enum QueueBacklogColors {
    static func color(forStateType stateType: String?) -> Color {
        switch (stateType ?? "").lowercased() {
        case "completed": return .green
        case "canceled", "cancelled": return .gray
        case "started": return .blue
        case "unstarted": return .orange
        case "backlog": return .secondary
        case "triage": return .purple
        default: return .secondary
        }
    }
}

private struct LegendView: View {
    var body: some View {
        HStack(spacing: 8) {
            legend(.blue, "in progress")
            legend(.orange, "todo")
            legend(.secondary, "backlog")
            legend(.green, "done")
        }
        .font(.system(size: 9)).foregroundStyle(.secondary)
    }

    private func legend(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(c.opacity(0.6)).frame(width: 8, height: 8)
            Text(label)
        }
    }
}

// MARK: - Window host

/// Opens / focuses a standalone resizable window hosting `QueueBacklogCanvas` for a run.
/// One window per run name (re-opening focuses the existing one). MainActor — invoked from
/// the dashboard's header button.
@MainActor
final class QueueBacklogWindowManager {
    static let shared = QueueBacklogWindowManager()
    private var windows: [String: NSWindow] = [:]
    private var observers: [String: NSObjectProtocol] = [:]

    /// A comfortable minimum so a tiny board (or none yet) still opens as a usable window.
    static let minContentSize = CGSize(width: 480, height: 360)
    /// Leave this much of the screen free so the title bar + edges stay reachable.
    static let screenMargin: CGFloat = 80

    /// PURE: the window's default CONTENT size — the board's preferred size (fit-to-content)
    /// floored at `minContentSize` and clamped to `screen` (minus a margin) so a large graph
    /// never opens bigger than the display. `screen` nil ⇒ no clamp (a sane fallback for a
    /// headless/test context). Unit-tested.
    static func defaultContentSize(nodes: [QueueGraph.Node], screen: CGSize?) -> CGSize {
        let pref = QueueBacklogGeometry.preferredWindowSize(nodes)
        var w = max(pref.width, minContentSize.width)
        var h = max(pref.height, minContentSize.height)
        if let screen {
            // Clamp to the display, but never below the minimum (a small screen still gets a
            // usable window even if that means it slightly exceeds the margin).
            w = min(w, max(minContentSize.width, screen.width - screenMargin))
            h = min(h, max(minContentSize.height, screen.height - screenMargin))
        }
        return CGSize(width: w, height: h)
    }

    func open(runName: String, model: AgentDashboardModel, onJumpToKey: @escaping (String) -> Void) {
        if let existing = windows[runName] {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let root = QueueBacklogCanvas(model: model, runName: runName, onJumpToKey: onJumpToKey)
        // Default size = big enough to show the whole board, clamped to the display so a huge
        // graph never opens off-screen. A small board floors at a comfortable minimum.
        let size = Self.defaultContentSize(
            nodes: model.queueGraphs[runName]?.nodes ?? [],
            screen: NSScreen.main?.visibleFrame.size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Backlog — \(runName)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        windows[runName] = window

        // Drop our strong ref when the user closes it (so it rebuilds fresh next time).
        observers[runName] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.windows.removeValue(forKey: runName)
            if let obs = self.observers.removeValue(forKey: runName) {
                NotificationCenter.default.removeObserver(obs)
            }
        }
    }
}
