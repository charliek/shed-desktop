// SidebarView.swift — the four panes + the configured-hosts list.

import ShedKit
import SwiftUI

struct SidebarView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row(.sheds, "server.rack", "Sheds", count: state.sheds.count)
            row(.approvals, "lock.shield", "Approvals", count: state.approvals.isEmpty ? nil : state.approvals.count, danger: true)
            row(.agents, "wand.and.stars", "Agents", count: state.rcSessions.isEmpty ? nil : state.rcSessions.count)
            row(.activity, "list.bullet.rectangle", "Activity", count: nil)
            row(.system, "internaldrive", "System", count: nil)

            Divider().padding(.vertical, 10)

            Text("Hosts")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.leading, 8)
                .padding(.bottom, 4)
            ForEach(state.hosts, id: \.name) { host in
                HStack(spacing: 7) {
                    Circle()
                        .fill(host.reachable ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(host.name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
    }

    @ViewBuilder
    private func row(_ pane: DashboardPane, _ icon: String, _ label: String, count: Int?, danger: Bool = false) -> some View {
        let selected = state.pane == pane
        Button {
            state.pane = pane
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                    .font(.system(size: 14))
                Text(label).font(.system(size: 13))
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11))
                        .foregroundStyle(danger ? Color.red : Color.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background((danger ? Color.red : Color.secondary).opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Theme.surface : Color.clear)
                    .shadow(color: selected ? .black.opacity(0.06) : .clear, radius: 1.5, y: 1)
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            // Make the whole padded row the hit target, not just the text +
            // icon (a Button with a Spacer otherwise only clicks on its content).
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
