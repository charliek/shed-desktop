// SystemView.swift — per-host server disk usage (M7, GET /api/system/df).

import ShedKit
import SwiftUI

struct SystemView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("System").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { state.onSystemRefresh?() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 4)
            Text("Disk usage per host (images, sheds, snapshots, orphans).")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .padding(.horizontal, 18).padding(.bottom, 10)

            if state.systemUsage.isEmpty {
                VStack { Spacer()
                    Text("Refreshing disk usage…").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(state.systemUsage) { row in
                            HostUsageCard(row: row)
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 16)
                }
            }
        }
        // Auto-fetch on first open; later refreshes are explicit (the button)
        // so re-navigation doesn't trigger a fetch storm.
        .onAppear { if state.systemUsage.isEmpty { state.onSystemRefresh?() } }
    }
}

private struct HostUsageCard: View {
    let row: HostDiskUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                Text(row.host).font(.system(size: 14, weight: .medium))
                if let backend = row.usage?.backend {
                    Text(backend).font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                if let t = row.usage?.totals {
                    Text(SystemView.bytes(t.all.physicalBytes)).font(.system(size: 13, weight: .semibold))
                }
            }
            if let error = row.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
            } else if let t = row.usage?.totals {
                HStack(spacing: 16) {
                    metric("Images", t.images.physicalBytes)
                    metric("Sheds", t.sheds.physicalBytes)
                    metric("Snapshots", t.snapshots.physicalBytes)
                    metric("Orphans", t.orphans.physicalBytes)
                }
            }
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
    }

    private func metric(_ label: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(SystemView.bytes(bytes)).font(.system(size: 12, design: .monospaced))
        }
    }
}

extension SystemView {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
