import SwiftUI

/// (ramon fork / Agent Dashboard, Layer 3) The dashboard surface: a vertical
/// stack of full-width agent preview rows plus the six non-blank degraded states
/// and the "N hidden" affordance.
struct AgentDashboardView: View {
    @ObservedObject var model: AgentDashboardModel
    let ghostty: Ghostty.App
    let ptyHostEnabled: Bool
    let commands: [String]

    /// Whether the "N hidden" popover is expanded.
    @State private var showHiddenPopover = false

    var body: some View {
        VStack(spacing: 0) {
            content
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        if model.liveIDs.isEmpty {
            // (1) No terminal windows at all. This takes priority over the
            // pty-host-off banner: with zero terminals "No terminals open." is
            // the informative message, and the pty-host-off state (spec §2.6) is
            // only meant to surface when agents EXIST but previews can't render —
            // which is handled by the in-grid banner below, never here.
            degraded(title: "No terminals open.", detail: "Open a terminal to see running agents here.")
        } else if model.entries.isEmpty {
            // Either every agent is hidden, or there are terminals but no agents.
            let hiddenLive = model.hiddenCount(among: model.liveAgentIDs)
            if hiddenLive > 0 {
                // (6) All agents hidden → collapse to the chip (rendered in footer);
                // show a gentle prompt in the body.
                degraded(title: "\(hiddenLive) hidden", detail: "Use the chip below to reveal agents.")
            } else {
                // (2) Terminals open, zero agents detected.
                degraded(
                    title: "No CLI agents running.",
                    detail: "Watching for: \(commands.joined(separator: ", ")) · polling every ~2s."
                )
            }
        } else {
            // Full-width rows in a List so `.onMove` gives drag-to-reorder for
            // free (the dashboard is already a single column). The list chrome is
            // stripped (plain style, hidden separators/background, clear rows) so
            // the tiles keep their card look. Row insets are zeroed on the LEADING
            // and TRAILING edges so tiles span EDGE-TO-EDGE (no side gutter) — only
            // a small top/bottom inset remains to separate stacked cards. (Plain
            // `List` otherwise reserves a horizontal gutter; explicit zero insets
            // override it.) Reordering does NOT remount the mirror previews —
            // `ForEach` identity stays `entry.id` and the mirror's `.id(sessionID)`
            // is untouched.
            List {
                if !ptyHostEnabled {
                    banner("Live previews require pty-host. Showing metadata-only tiles.")
                        .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .moveDisabled(true)
                }
                ForEach(model.entries) { entry in
                    AgentPreviewTile(
                        entry: entry,
                        ghostty: ghostty,
                        previewsEnabled: ptyHostEnabled,
                        onHide: { model.hide(entry.id) },
                        onApprove: { text in model.approveSuggestion(entry.id, text) },
                        onDismiss: { model.dismissSuggestion(entry.id) },
                        onSetNote: { text in model.setUserNotes(entry.id, text) }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
                .onMove { source, destination in
                    // Capture the displayed session-id order (WYSIWYG), apply the
                    // move, and hand the new full order to the model to persist.
                    var ids = model.entries.map(\.sessionID)
                    ids.move(fromOffsets: source, toOffset: destination)
                    model.setManualOrder(ids)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            // Plain `List` still reserves a ~5–10pt horizontal scroll-content
            // margin that `listRowInsets` can't reach; zero it so the tiles are
            // truly edge-to-edge (the user's "full-width rows" ask). The API is
            // macOS 14+, so it's behind an availability shim (older deploy
            // targets keep the small gutter — graceful degradation).
            .zeroHorizontalScrollMargin()
            .animation(.easeInOut(duration: 0.18), value: model.entries.map(\.id))
        }
    }

    @ViewBuilder
    private var footer: some View {
        let hiddenLive = model.hiddenCount(among: model.liveAgentIDs)
        // Only offer "Reset order" when there's actually a list to reorder (not
        // floating over a degraded "No terminals / agents" state).
        let showReset = model.hasManualOrder && !model.entries.isEmpty
        if hiddenLive > 0 || showReset {
            HStack {
                if hiddenLive > 0 {
                    Button {
                        showHiddenPopover.toggle()
                    } label: {
                        Label("\(hiddenLive) hidden", systemImage: "eye.slash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $showHiddenPopover) {
                        hiddenPopover
                    }
                }
                Spacer()
                if showReset {
                    // Escape hatch from a manual drag order back to the automatic
                    // attention-first / recent-activity sort.
                    Button {
                        model.resetOrder()
                    } label: {
                        Label("Reset order", systemImage: "arrow.up.arrow.down")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("Clear your manual order and sort by recent activity")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var hiddenPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Hidden agents").font(.headline)
            // badge · title · Show (spec §4.3). Metadata is retained from the
            // live snapshot even though the entry is filtered out while hidden.
            ForEach(model.hiddenAgents) { agent in
                HStack(spacing: 6) {
                    Text(agent.agent?.command ?? "•")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18))
                        .clipShape(Capsule())
                    Text(agent.title.isEmpty ? "(untitled)" : agent.title)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Button("Show") { model.show(agent.id) }
                        .buttonStyle(.borderless)
                }
            }
            Divider()
            Button("Show all") { model.showAll(); showHiddenPopover = false }
        }
        .padding(12)
        .frame(width: 240)
    }

    private func degraded(title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(.yellow.opacity(0.12))
    }
}

private extension View {
    /// Zero the horizontal scroll-content margin of a `List`/scroll view so its
    /// rows reach the container edges. `contentMargins(_:_:for:)` is macOS 14+,
    /// so on older systems this is a no-op (the small default gutter remains).
    @ViewBuilder
    func zeroHorizontalScrollMargin() -> some View {
        if #available(macOS 14.0, *) {
            self.contentMargins(.horizontal, 0, for: .scrollContent)
        } else {
            self
        }
    }
}
