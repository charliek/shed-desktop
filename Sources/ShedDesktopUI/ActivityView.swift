// ActivityView.swift — the merged activity feed (M3): host-agent audit +
// the app's own approval decisions + lifecycle/RC.

import ShedKit
import SwiftUI

struct ActivityView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { state.onRevealAuditLog?() } label: {
                    Label("Reveal log", systemImage: "doc.text.magnifyingglass").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .help("Reveal the append-only audit log in Finder.")
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 4)
            Text("Host-agent credential audit + shed-desktop decisions, newest first.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .padding(.horizontal, 18).padding(.bottom, 8)

            if state.activity.isEmpty {
                VStack { Spacer()
                    Text("No activity yet.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(state.activity.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider() }
                            ActivityRow(entry: entry)
                        }
                    }
                    .padding(.horizontal, 12)
                    .background {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Theme.surface)
                            .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
                    }
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                }
            }
        }
    }
}

struct ActivityRow: View {
    let entry: AuditEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(shortTime).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).frame(width: 64, alignment: .leading)
            if let ns = entry.ns { Badge(ns) }
            Text(opLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Text(entry.result)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(resultColor)
            if let approval = entry.approval, approval != "none" {
                Text(approval).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 7)
    }

    private var shortTime: String { DateFormatting.shortTime(entry.ts) }

    private var opLine: String {
        var parts: [String] = []
        if let op = entry.op { parts.append(op) }
        if let shed = entry.shed { parts.append(entry.server.map { "\($0)/\(shed)" } ?? shed) }
        if let detail = entry.detail { parts.append(detail) }
        return parts.joined(separator: " · ")
    }

    private var resultColor: Color { Theme.auditResultColor(entry.result) }
}
