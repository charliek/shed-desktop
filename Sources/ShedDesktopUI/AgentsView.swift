// AgentsView.swift — the remote-control agents pane (M2).

import ShedKit
import SwiftUI

struct AgentsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Remote-control agents").font(.system(size: 16, weight: .semibold))
                Spacer()
                Button { state.onRcRefresh?() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
                Button { state.showLaunchSheet = true } label: {
                    Label("Launch agent", systemImage: "plus").font(.system(size: 13))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            if state.rcSessions.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(state.rcSessions) { session in
                            AgentRow(session: session, state: state)
                        }
                    }
                    .padding(.horizontal, 18).padding(.bottom, 16)
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "wand.and.stars").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text("No remote-control sessions. Launch one into a running shed.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct AgentRow: View {
    let session: RcSession
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            StatePill(session.state)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("\(session.shed)/\(session.displayName)").font(.system(size: 14, weight: .medium))
                    Badge(session.kind.rawValue)
                }
                Text(metaLine).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if needsFix {
                Text(fixHint).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
            }
            if let url = session.url, session.state == .ready {
                Button { state.onOpenURL?(url) } label: {
                    Label("Open in Claude", systemImage: "arrow.up.right.square").font(.system(size: 12))
                }
                .buttonStyle(.bordered)
            }
            Button { state.onRcKill?(session) } label: { Image(systemName: "trash").font(.system(size: 12)) }
                .buttonStyle(.bordered).help("Kill session")
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border, lineWidth: 0.5))
    }

    private var metaLine: String {
        "tmux \(session.tmuxSession) · \(session.workdir)"
    }

    private var needsFix: Bool {
        session.state == .needsTrust || session.state == .needsAuth
    }

    private var fixHint: String {
        switch session.state {
        case .needsTrust: return "attach + trust the folder, then relaunch"
        case .needsAuth: return "attach + claude auth login, then relaunch"
        default: return ""
        }
    }
}

struct StatePill: View {
    let state: RcState
    init(_ state: RcState) { self.state = state }
    var body: some View {
        let color = Theme.rcStateColor(state)
        Text(state.rawValue)
            .font(.system(size: 11, weight: .medium))
            .frame(width: 84)
            .padding(.vertical, 3)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
