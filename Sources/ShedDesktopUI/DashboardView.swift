// DashboardView.swift — the main window: header + sidebar + content pane.

import ShedKit
import SwiftUI

public struct DashboardView: View {
    @ObservedObject var state: AppState

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                SidebarView(state: state)
                    .frame(width: Theme.sidebarWidth)
                Divider()
                contentPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $state.showCreateSheet) {
            CreateShedSheet(state: state)
        }
        .sheet(isPresented: $state.showLaunchSheet) {
            AgentLaunchSheet(state: state)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .foregroundStyle(.secondary)
            Text("shed desktop")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(state.hostAgentConnected ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(state.hostAgentConnected ? "host agent · connected" : "host agent · not connected")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    @ViewBuilder
    private var contentPane: some View {
        switch state.pane {
        case .sheds:
            ShedListView(state: state)
        case .approvals:
            PlaceholderPane(
                title: "Credential approvals",
                systemImage: "lock.shield",
                message: "Approvals route here when the host agent's mode is shed-desktop (M3)."
            )
        case .agents:
            AgentsView(state: state)
        case .activity:
            PlaceholderPane(
                title: "Activity",
                systemImage: "list.bullet.rectangle",
                message: "Merged credential audit + lifecycle + RC state changes (M3)."
            )
        }
    }
}

struct PlaceholderPane: View {
    let title: String
    let systemImage: String
    let message: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 16, weight: .semibold))
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .frame(maxWidth: .infinity)
            Spacer()
        }
        .padding(18)
    }
}
