import SwiftUI

/// (ramon fork / Agent Dashboard, Layer 3) The dashboard surface: a wrapping
/// grid of agent preview tiles plus the six non-blank degraded states and the
/// "N hidden" affordance.
struct AgentDashboardView: View {
    @ObservedObject var model: AgentDashboardModel
    let ghostty: Ghostty.App
    let ptyHostEnabled: Bool
    let commands: [String]

    /// Whether the "N hidden" popover is expanded.
    @State private var showHiddenPopover = false

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 480), spacing: 12)]

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
            ScrollView {
                if !ptyHostEnabled {
                    banner("Live previews require pty-host. Showing metadata-only tiles.")
                }
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.entries) { entry in
                        AgentPreviewTile(
                            entry: entry,
                            ghostty: ghostty,
                            previewsEnabled: ptyHostEnabled,
                            onHide: { model.hide(entry.id) }
                        )
                    }
                }
                .padding(12)
                .animation(.easeInOut(duration: 0.18), value: model.entries.map(\.id))
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        let hiddenLive = model.hiddenCount(among: model.liveAgentIDs)
        if hiddenLive > 0 {
            HStack {
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
                Spacer()
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
