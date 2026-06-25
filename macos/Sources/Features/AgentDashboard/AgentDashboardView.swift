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
        } else if model.entries.isEmpty && model.queueStatuses.isEmpty {
            // Either every agent is hidden, or there are terminals but no agents — AND no
            // queue is running. (§11 health) When a queue IS present we fall through to the
            // sectioned list instead, so its bar — controls + "N waiting · next: …" — stays
            // visible even with zero/all-hidden tiles (the queue is still there).
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
                // toggle per known origin. Shown when there's more than one origin to
                // choose between (a single-origin fleet needs no filter) OR whenever an
                // exclusion is active — otherwise a stale exclusion (e.g. soloing a
                // queue that later ends, leaving `(other)` excluded as the sole origin)
                // would silently filter out every tile with NO way to reach "Show all".
                if model.showsFilterBar {
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
                // A lone `(other)` section (the legacy, no-queue case) shows no
                // header — keep the classic flat look until a queue origin exists.
                // Without a header there's no collapse affordance, so it never
                // collapses; once there are 2+ origins, every section is labeled
                // and collapsible.
                let hasHeader = !(model.sections.count == 1 && section.isOther)
                let collapsed = hasHeader && model.isCollapsed(section.id)
                Section {
                    if !collapsed {
                        ForEach(section.entries) { entry in
                            AgentPreviewTile(
                                entry: entry,
                                ghostty: ghostty,
                                previewsEnabled: ptyHostEnabled,
                                onHide: { model.hide(entry.id) },
                                onClose: { model.closeSurface(entry.id) }
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
                    }
                } header: {
                    if hasHeader {
                        OriginSectionHeader(
                            section: section,
                            collapsed: collapsed,
                            onToggleCollapse: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    model.toggleCollapsed(section.id)
                                }
                            },
                            status: model.queueStatuses[section.id],
                            onPause: { model.sendRunCommand(.pause, run: section.id) },
                            onResume: { model.sendRunCommand(.resume, run: section.id) },
                            onStop: { model.sendRunCommand(.stop, run: section.id) },
                            onAbort: { model.sendRunCommand(.abort, run: section.id) },
                            onGoToItem: { item in
                                // Resolve the running item → its split UUID and jump to it.
                                if let id = model.surfaceID(forQueue: section.id, key: item.key) {
                                    focusHidden(id)
                                }
                            },
                            onSetMaxItems: { value in
                                model.setQueueMaxItems(run: section.id, value: value)
                            },
                            graph: model.queueGraphs[section.id],
                            onOpenBacklog: {
                                QueueBacklogWindowManager.shared.open(
                                    runName: section.id, model: model,
                                    onJumpToKey: { key in
                                        if let id = model.surfaceID(forQueue: section.id, key: key) {
                                            focusHidden(id)
                                        }
                                    })
                            }
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
                        // Tap to SHOW ONLY this origin (solo); tap the soloed one again to
                        // show all. (Was: tap to hide that origin.)
                        model.soloOrigin(origin)
                    } label: {
                        Text(origin)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            // High-contrast: WHITE on a solid accent fill when shown; muted
                            // grey when filtered out (blue-on-dark-blue was unreadable).
                            .foregroundStyle(included ? Color.white : Color.secondary)
                            .background(included ? Color.accentColor : Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                            .opacity(included ? 1.0 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .help(included ? "Show only \(origin)" : "Show only \(origin)")
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
                    // Clicking the NAME focuses (jumps to) that split — raise its
                    // window, select its tab, un-zoom if hidden — WITHOUT unhiding it
                    // from the dashboard. "Show" (below) is the unhide affordance.
                    Button {
                        focusHidden(agent.id)
                        showHiddenPopover = false
                    } label: {
                        Text(agent.title.isEmpty ? "(untitled)" : agent.title)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.link)
                    .help("Jump to this split")
                    Spacer(minLength: 4)
                    Button("Show") { model.show(agent.id) }
                        .buttonStyle(.borderless)
                }
            }
            Divider()
            Button("Show all") { model.showAll(); showHiddenPopover = false }
        }
        .padding(12)
        .frame(width: 560)
    }

    /// Focus (jump to) a hidden split by id without unhiding it: raise its window,
    /// select its tab, un-zoom if hidden, and flash the present highlight — the same
    /// path a visible tile's tap uses (`AgentPreviewTile.jump`). Deferred to the next
    /// runloop so the present runs AFTER AppKit settles the panel's key-window change
    /// from this click (see the note in `AgentPreviewTile.jump`).
    private func focusHidden(_ id: UUID) {
        DispatchQueue.main.async {
            for controller in TerminalController.all {
                for v in controller.surfaceTree where v.id == id {
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
    /// Whether this section is collapsed (tiles hidden). When collapsed the header
    /// shows a compact "unhidden / total · bells" summary in place of the tiles.
    let collapsed: Bool
    /// Toggle this section's collapsed state (the disclosure chevron gesture).
    let onToggleCollapse: () -> Void
    /// (§11 health) The run's latest health snapshot, when the supervisor has reported
    /// one. nil for `(other)` and for a queue that hasn't reported yet.
    let status: QueueStatus?
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onAbort: () -> Void
    /// (§11 health) Jump to the split running a given queue item (the "go to" affordance in
    /// the running dropdown). The parent resolves the item's surface + presents it.
    let onGoToItem: (QueueStatus.Item) -> Void
    /// (live maxItems edit) Re-set this run's lifetime cap (the dashboard cap control). The
    /// raw user string ("10"/"unlimited"/…) is posted as a `set_max_items` command; the
    /// sidecar parses it (blank/garbage = ignored).
    let onSetMaxItems: (String) -> Void
    /// (backlog graph) The run's latest whole-board snapshot, when the supervisor has pushed
    /// one (only when the template declares `provider.graph`). nil ⇒ no backlog button.
    let graph: QueueGraph?
    /// (backlog graph) Open the dependency-graph canvas for this run.
    let onOpenBacklog: () -> Void

    // Stop and Abort discard in-flight work and have no undo, so they confirm
    // before firing (Pause/Resume are cheap + reversible, so they stay one-tap).
    @State private var confirmStop = false
    @State private var confirmAbort = false
    // (§11 health) The "N waiting" / "M running" count dropdowns (items + Linear links).
    @State private var showWaiting = false
    @State private var showRunning = false
    // (live maxItems edit) The "dispatched/cap" tap-to-edit popover + its draft field.
    @State private var showCapEditor = false
    @State private var capDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // Disclosure chevron — collapse/expand the section's tiles.
                Button(action: onToggleCollapse) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Expand section" : "Collapse section")
                Text(section.id)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if collapsed {
                    // The tiles are hidden, so surface their counts: unhidden /
                    // total + the number of bells ringing in this section.
                    collapsedSummary
                } else {
                    Text("\(section.count)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.18))
                        .clipShape(Capsule())
                }
                Spacer(minLength: 4)
                if !section.isOther {
                    // Cheap run-control intents (§8/§11). Pause and Resume are both
                    // offered (the model holds no run state, so we can't know which is
                    // active — the sidecar treats the inactive one as a no-op). Stop and
                    // Abort confirm first (no undo).
                    queueButton("pause", help: "Pause: stop dispatching new agents", action: onPause)
                    queueButton("play", help: "Resume dispatching", action: onResume)
                    queueButton("stop", help: "Stop: drain, no new agents") { confirmStop = true }
                    queueButton("xmark.octagon", help: "Abort: force-close all agents in this run") { confirmAbort = true }
                }
            }
            // (§11 health) The run-level status line: a phase chip + "running/waiting/
            // progress" + the next items — so you can SEE the queue is alive and what it's
            // about to do, even before any split spawns.
            if let status {
                HStack(spacing: 6) {
                    phaseChip(status.phase)
                    if status.listOk {
                        // Clickable counts → a dropdown of the items with Linear links
                        // (mirrors the hidden-agents popover).
                        countButton("\(status.queued) waiting", items: status.next,
                                    total: status.queued, show: $showWaiting,
                                    emptyText: "Nothing waiting.", onGoTo: nil)
                        // Running items get a "go to" affordance → jump to that split.
                        countButton("\(status.active) running", items: status.running,
                                    total: status.active, show: $showRunning,
                                    emptyText: "Nothing running.",
                                    onGoTo: { item in
                                        onGoToItem(item)
                                        showRunning = false
                                    })
                        // The "dispatched/cap" suffix is tap-to-edit: open a small editor
                        // to raise/lower the lifetime cap WITHOUT restarting the run.
                        Button {
                            capDraft = QueueHealthFormat.capDraft(status)
                            showCapEditor = true
                        } label: {
                            Text(QueueHealthFormat.progressText(status))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Change the lifetime cap (maxItems) for this run")
                        .popover(isPresented: $showCapEditor, arrowEdge: .bottom) {
                            capEditorPopover(status)
                        }
                    } else {
                        Text("reading the queue…").font(.caption2).foregroundStyle(.secondary)
                    }
                    // (backlog graph) The "N backlog" button → the dependency-graph canvas,
                    // inline at the end of the status line (after the dispatched/cap chip).
                    // The row is full-width with a trailing Spacer, so this sits in the empty
                    // space to the right of the counts. Shown whenever the run reports a board.
                    if let graph {
                        backlogButton(graph)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog(
            "Stop queue “\(section.id)”?",
            isPresented: $confirmStop,
            titleVisibility: .visible
        ) {
            Button("Stop (drain)", action: onStop)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops dispatching new agents. In-flight agents finish their current work, then the run is removed. This can't be undone — you'd have to re-start the queue.")
        }
        .confirmationDialog(
            "Abort queue “\(section.id)”?",
            isPresented: $confirmAbort,
            titleVisibility: .visible
        ) {
            Button("Abort (force-close all)", role: .destructive, action: onAbort)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Immediately force-closes all \(section.count) agent split\(section.count == 1 ? "" : "s") in this run, discarding any in-progress work.")
        }
    }

    /// (backlog graph) The "N backlog" button that opens the dependency-graph canvas. The
    /// count is the sidecar-derived groomable remainder (non-terminal, not waiting/running).
    @ViewBuilder
    private func backlogButton(_ graph: QueueGraph) -> some View {
        Button(action: onOpenBacklog) {
            HStack(spacing: 3) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                Text("\(graph.backlog) backlog")
            }
            .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Open the backlog dependency graph (\(graph.nodes.count) items in scope)")
    }

    /// The compact collapsed-section summary: unhidden count, total count, and the
    /// number of bells ringing — shown in the header when the section's tiles are
    /// hidden so the counts aren't lost behind the collapse.
    @ViewBuilder
    private var collapsedSummary: some View {
        HStack(spacing: 4) {
            // "{unhidden} of {total}" when some agents are hidden; just the count
            // (in a capsule, matching the expanded look) when none are hidden.
            if section.hiddenCount > 0 {
                Text("\(section.count) of \(section.totalCount)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
                    .help("\(section.count) shown · \(section.hiddenCount) hidden · \(section.totalCount) total")
            } else {
                Text("\(section.totalCount)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
            }
            if section.bellCount > 0 {
                Label("\(section.bellCount)", systemImage: "bell.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .help("\(section.bellCount) agent\(section.bellCount == 1 ? "" : "s") ringing the bell")
            }
        }
    }

    @ViewBuilder
    private func phaseChip(_ phase: String) -> some View {
        let color = QueueHealthFormat.phaseColor(phase)
        Text(phase)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.16))
            .clipShape(Capsule())
    }

    /// (live maxItems edit) The tap-to-edit cap popover: quick presets + a custom field.
    /// Commits the raw string (the sidecar parses + ignores garbage), so a fat-finger
    /// never silently removes the cap.
    @ViewBuilder
    private func capEditorPopover(_ status: QueueStatus) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Lifetime cap (maxItems)").font(.caption.weight(.semibold))
            // lineLimit(nil) is explicit so an inherited limit can't collapse this to one
            // truncated line; fixedSize(vertical) lets it grow to however many lines it needs.
            Text("Dispatched \(status.dispatched) of \(status.maxItems.map(String.init) ?? "∞"). Raising it lets the run pick up more items; lowering it only stops FUTURE dispatch — running agents keep going.")
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            // Relative bumps (raise the current cap) — the quick "pull in a little more"
            // gesture. Only meaningful for a FINITE cap; hidden when unlimited.
            if let plusOne = QueueHealthFormat.capPlus(status, 1) {
                HStack(spacing: 6) {
                    Button("+1") { commitCap(String(plusOne)) }
                        .buttonStyle(.bordered)
                        .help("Pull in one more item (raise the cap by 1)")
                    if status.queued > 0,
                       let plusWaiting = QueueHealthFormat.capPlus(status, status.queued) {
                        Button("+ all waiting (\(status.queued))") { commitCap(String(plusWaiting)) }
                            .buttonStyle(.bordered)
                            .help("Raise the cap by the \(status.queued) waiting item\(status.queued == 1 ? "" : "s"), so they all dispatch and nothing after them")
                    }
                }
            }
            // Absolute presets.
            HStack(spacing: 6) {
                ForEach(["1", "2", "5", "10"], id: \.self) { v in
                    Button(v) { commitCap(v) }.buttonStyle(.bordered)
                }
                Button("∞") { commitCap("unlimited") }
                    .buttonStyle(.bordered)
                    .help("Unlimited — no lifetime cap")
            }
            HStack(spacing: 6) {
                TextField("custom", text: $capDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onSubmit { commitCap(capDraft) }
                Button("Set") { commitCap(capDraft) }
                    .buttonStyle(.borderedProminent)
                    .disabled(capDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private func commitCap(_ value: String) {
        onSetMaxItems(value)
        showCapEditor = false
    }

    private func queueButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage).font(.caption2)
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    /// A clickable count chip ("N waiting" / "M running") that opens a popover listing
    /// the items with Linear links. Styled as a subtle link so it reads as a count.
    private func countButton(
        _ label: String, items: [QueueStatus.Item], total: Int,
        show: Binding<Bool>, emptyText: String, onGoTo: ((QueueStatus.Item) -> Void)?
    ) -> some View {
        Button { show.wrappedValue.toggle() } label: {
            Text(label).font(.caption2)
        }
        .buttonStyle(.link)
        .help("Show items")
        .popover(isPresented: show, arrowEdge: .bottom) {
            itemsPopover(title: label, items: items, total: total, emptyText: emptyText, onGoTo: onGoTo)
        }
    }

    /// The popover body for a count chip: one row per item (key badge · title · Linear
    /// link), plus a "… and N more" note when the list was capped below the total. When
    /// `onGoTo` is non-nil (the running list) each row also gets a "go to" button that
    /// jumps to that split. All text via `Text`/`Link` (SwiftUI escapes it — the
    /// key/title/url are untrusted tracker data; only http(s) urls are made clickable).
    @ViewBuilder
    private func itemsPopover(
        title: String, items: [QueueStatus.Item], total: Int, emptyText: String,
        onGoTo: ((QueueStatus.Item) -> Void)?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if items.isEmpty {
                Text(emptyText).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Text(item.key)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.18))
                            .clipShape(Capsule())
                        itemLink(item)
                        Spacer(minLength: 4)
                        if let onGoTo {
                            Button { onGoTo(item) } label: {
                                Image(systemName: "arrow.right.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Go to this split")
                        }
                    }
                }
                if total > items.count {
                    Text("… and \(total - items.count) more")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 420)
    }


    /// The item's title as a Linear `Link` when it carries an http(s) url; else plain text.
    @ViewBuilder
    private func itemLink(_ item: QueueStatus.Item) -> some View {
        let text = (item.title?.isEmpty == false) ? item.title! : item.key
        if let urlString = item.url,
           let url = URL(string: urlString),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            Link(text, destination: url)
                .font(.caption).lineLimit(1).truncationMode(.middle)
        } else {
            Text(text).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }
}

/// (ramon fork / Agent Queue, §11 health) PURE formatting for the queue bar's status
/// line — split out (internal) so it is unit-testable independent of the SwiftUI view.
enum QueueHealthFormat {
    /// The lifetime-progress suffix shown after the clickable counts: "{dispatched}/{cap}"
    /// with ∞ for an unlimited cap — so a reached maxItems (e.g. 1/1) is visible at a glance.
    static func progressText(_ s: QueueStatus) -> String {
        let cap = s.maxItems.map(String.init) ?? "∞"
        return "\(s.dispatched)/\(cap)"
    }

    /// (live maxItems edit) The pre-fill for the cap editor's custom field: the current
    /// FINITE cap as a string, or "" for an unlimited cap (the field starts empty so the
    /// user either picks ∞ or types a number). PURE, unit-tested.
    static func capDraft(_ s: QueueStatus) -> String {
        s.maxItems.map(String.init) ?? ""
    }

    /// (relative cap edits) The new ABSOLUTE cap when raising the current FINITE cap by
    /// `delta` — backs the "+1" / "+ all waiting" buttons (delta = 1 or `queued`). The
    /// goal is "pull in N more, then stop": at the common steady state (dispatched == cap)
    /// `cap + delta` lets exactly `delta` more dispatch before the cap is reached again.
    /// Returns nil for an unlimited cap (`maxItems == nil`), where a relative bump is
    /// meaningless (everything already dispatches) — the caller hides the buttons then.
    /// Clamped at ≥ 0 (a negative delta can never push the cap below zero). PURE, unit-tested.
    static func capPlus(_ s: QueueStatus, _ delta: Int) -> Int? {
        guard let cap = s.maxItems else { return nil }
        return max(0, cap + delta)
    }

    /// The accent color for a phase chip.
    static func phaseColor(_ phase: String) -> Color {
        switch phase {
        case "running": return .green
        case "starting": return .blue
        case "paused", "draining": return .orange
        case "disabled": return .red
        default: return .secondary
        }
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
