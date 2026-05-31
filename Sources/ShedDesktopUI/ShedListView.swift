// ShedListView.swift — the read-only shed dashboard (M0), grouped by host.

import ShedKit
import SwiftUI

struct ShedListView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Sheds").font(.system(size: 16, weight: .semibold))
                Spacer()
                if let err = state.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 10)

            if state.sheds.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(state.shedsByHost(), id: \.host.name) { group in
                            if !group.sheds.isEmpty {
                                hostSection(group.host, group.sheds)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(state.hosts.contains(where: \.reachable)
                 ? "No sheds across the reachable hosts."
                 : "No reachable hosts. Check ~/.shed/config.yaml and that shed-server is running.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func hostSection(_ host: ShedHost, _ sheds: [Shed]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(host.name.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
            ForEach(sheds) { shed in
                ShedRow(shed: shed)
            }
        }
    }
}

struct ShedRow: View {
    let shed: Shed

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(Theme.statusColor(shed.status))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(shed.name).font(.system(size: 14, weight: .medium))
                    if let backend = shed.backend { Badge(backend, prominent: true) }
                    if let image = shed.image { Badge(image) }
                }
                Text(metaLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !shed.activeNamespaces.isEmpty {
                Label(shed.activeNamespaces.joined(separator: " · "), systemImage: "key")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 0.5))
        .opacity(shed.status == .stopped ? 0.6 : 1.0)
    }

    private var metaLine: String {
        if shed.status == .starting { return "starting…" }
        var parts: [String] = []
        if let repo = shed.repo { parts.append(repo) }
        else if let dir = shed.localDir { parts.append(dir) }
        if let cpus = shed.cpus { parts.append("\(cpus) vCPU") }
        if let mem = shed.memoryMB { parts.append("\(mem / 1024) GB") }
        if shed.status == .running, let started = shed.startedAt,
           let date = DateFormatting.parseFlexibleTimestamp(started) {
            parts.append("up \(DateFormatting.shortRelative(date))")
        } else if shed.status == .stopped {
            parts.append("stopped")
        }
        return parts.isEmpty ? shed.status.rawValue : parts.joined(separator: " · ")
    }
}
