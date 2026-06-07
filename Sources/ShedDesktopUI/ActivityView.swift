// ActivityView.swift — the merged activity feed (M3): host-agent audit +
// the app's own approval decisions + lifecycle/RC.

import ShedKit
import SwiftUI

struct ActivityView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Activity").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button { state.onRevealAuditLog?() } label: {
                    Label("Reveal log", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Reveal the append-only audit log in Finder.")
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)
            Text("Host-agent credential audit + shed-desktop decisions, newest first.")
                .font(.system(size: 12)).foregroundStyle(Theme.textMuted)
                .padding(.horizontal, 20).padding(.bottom, 10)

            if state.activity.isEmpty {
                VStack { Spacer()
                    Text("No activity yet.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
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
                    .padding(.horizontal, 14)
                    .cardSurface()
                    .padding(.horizontal, 20)
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
            Text(shortTime).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textMuted).frame(width: 66, alignment: .leading)
            if let ns = entry.ns { Badge(ns, tone: ns == "ssh-agent" ? .agent : .neutral) }
            Text(opLine).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Spacer()
            Text(entry.result)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(resultColor)
            if let approval = entry.approval, approval != "none" {
                Text(approval).font(.system(size: 11)).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.vertical, 8)
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
