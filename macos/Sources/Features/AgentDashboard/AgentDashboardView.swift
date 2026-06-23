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
            VStack(spacing: 0) {
                // (ramon fork / Agent Queue, §11) Filter bar: one include/exclude
                // toggle per known origin. Only shown when there's more than one
                // origin to choose between (a single-origin fleet needs no filter).
                if model.knownOrigins.count > 1 {
                    originFilterBar
                }
                sectionedList
            }
        }
    }

    // MARK: - Sectioned tile list (ramon fork / Agent Queue, §11)

    /// Full-width-ish rows in a List so `.onMove` gives drag-to-reorder for free.
    /// The list chrome is stripped (plain style, hidden separators/background,
    /// clear rows) so the tiles keep their card look. Tiles are grouped into
    /// origin SECTIONS, each with a header (origin name · count · queue controls).
    /// `.onMove` operates over the GLOBAL displayed order (across sections), so the
    /// captured session-id order spans every section — the model resorts and
    /// re-groups, so a drag still re-buckets cleanly. Reordering does NOT remount
    /// the mirror previews — the tile identity stays `entry.id` and the mirror's
    /// `.id(sessionID)` is untouched. The residual ~5–10pt horizontal `NSTableView`
    /// cell inset remains (see the original full-width note) — a deliberate trade to
    /// keep `.onMove`.
    @ViewBuilder
    private var sectionedList: some View {
        List {
            if !ptyHostEnabled {
                banner("Live previews require pty-host. Showing metadata-only tiles.")
                    .listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .moveDisabled(true)
            }
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.entries) { entry in
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
                        // Reorder ACROSS all sections: capture the global displayed
                        // session-id order, apply the in-section move at the right
                        // offset, then hand the full order to the model.
                        moveWithinSection(section, source: source, destination: destination)
                    }
                } header: {
                    // A lone `(other)` section (the legacy, no-queue case) shows no
                    // header — keep the classic flat look until a queue origin
                    // exists. Once there are 2+ origins, every section is labeled.
                    if !(model.sections.count == 1 && section.isOther) {
                        OriginSectionHeader(
                            section: section,
                            onPause: { model.sendRunCommand(.pause, run: section.id) },
                            onResume: { model.sendRunCommand(.resume, run: section.id) },
                            onStop: { model.sendRunCommand(.stop, run: section.id) },
                            onAbort: { model.sendRunCommand(.abort, run: section.id) }
                        )
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 2, trailing: 8))
                        .listRowBackground(Color.clear)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .zeroHorizontalScrollMargin()
        .animation(.easeInOut(duration: 0.18), value: model.entries.map(\.id))
    }

    /// Translate an in-section `.onMove` into a global session-id reorder. The
    /// section's tiles are a contiguous slice of the global displayed order; we
    /// rebuild the full order with the slice moved, then persist. Sessionless tiles
    /// (id 0) are filtered by the model on save.
    private func moveWithinSection(
        _ section: AgentDashboardModel.OriginSection,
        source: IndexSet, destination: Int
    ) {
        // Global displayed order across all sections (WYSIWYG).
        let global = model.sections.flatMap { $0.entries }.map(\.sessionID)
        // The section's own slice (in displayed order).
        var sectionIDs = section.entries.map(\.sessionID)
        sectionIDs.move(fromOffsets: source, toOffset: destination)
        // Splice the reordered slice back into the global order at the section's
        // first position, preserving the relative order of the other sections.
        let sectionSet = Set(section.entries.map(\.sessionID))
        var result: [UInt64] = []
        var spliced = false
        for sid in global {
            if sectionSet.contains(sid) {
                if !spliced { result.append(contentsOf: sectionIDs); spliced = true }
            } else {
                result.append(sid)
            }
        }
        if !spliced { result.append(contentsOf: sectionIDs) }
        model.setManualOrder(result)
    }

    /// The per-origin include/exclude filter bar (§11). A wrapping row of toggle
    /// chips, one per known origin, plus a "Show all" when anything is excluded.
    @ViewBuilder
    private var originFilterBar: some View {
        let origins = model.knownOrigins.sorted { a, b in
            if a == AgentDashboardModel.otherOrigin { return false }
            if b == AgentDashboardModel.otherOrigin { return true }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(origins, id: \.self) { origin in
                    let included = !model.excludedOrigins.contains(origin)
                    Button {
                        model.toggleOrigin(origin)
                    } label: {
                        Text(origin)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(included ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.12))
                            .foregroundStyle(included ? Color.accentColor : Color.secondary)
                            .clipShape(Capsule())
                            .opacity(included ? 1.0 : 0.6)
                    }
                    .buttonStyle(.plain)
                    .help(included ? "Hide \(origin) from the view" : "Show \(origin)")
                }
                if !model.excludedOrigins.isEmpty {
                    Button { model.showAllOrigins() } label: {
                        Text("Show all").font(.caption2)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.ultraThinMaterial)
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

/// (ramon fork / Agent Queue, §11) One origin section header: the origin name +
/// live tile count, and — for a queue origin (not `(other)`) — Pause/Stop/Abort
/// control buttons that post `.ghosttyQueueCommand` (run-control intents the
/// sidecar reconciles). The origin name is rendered via `Text` (SwiftUI escapes
/// it — `textContent`-safe; it is untrusted queue-template / annotation data).
private struct OriginSectionHeader: View {
    let section: AgentDashboardModel.OriginSection
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onAbort: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(section.id)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(section.count)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.18))
                .clipShape(Capsule())
            Spacer(minLength: 4)
            if !section.isOther {
                // Cheap run-control intents (§8/§11). Pause and Resume are both
                // offered (the model holds no run state, so we can't know which is
                // active — the sidecar treats the inactive one as a no-op).
                queueButton("pause", help: "Pause: stop dispatching new agents", action: onPause)
                queueButton("play", help: "Resume dispatching", action: onResume)
                queueButton("stop", help: "Stop: drain, no new agents", action: onStop)
                queueButton("xmark.octagon", help: "Abort: force-close all agents in this run", action: onAbort)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func queueButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.caption2)
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

private extension View {
    /// Zero the horizontal scroll-content margin of a `List`/scroll view.
    /// `contentMargins(_:_:for:)` is macOS 14+, so on older systems this is a
    /// no-op. NOTE for `List` specifically: this trims the scroll-content margin
    /// but NOT the underlying `NSTableView` cell inset, so a small residual
    /// horizontal gutter remains either way (see AgentDashboardView's row block).
    @ViewBuilder
    func zeroHorizontalScrollMargin() -> some View {
        if #available(macOS 14.0, *) {
            self.contentMargins(.horizontal, 0, for: .scrollContent)
        } else {
            self
        }
    }
}
