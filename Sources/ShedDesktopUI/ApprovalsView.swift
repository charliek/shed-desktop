// ApprovalsView.swift — the credential approval queue (M3, headline).

import ShedKit
import SwiftUI

struct ApprovalsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Credential approvals").font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(state.hostAgentConnected ? "gate: shed-desktop" : "host agent not connected")
                    .font(.system(size: 12))
                    .foregroundStyle(state.hostAgentConnected ? Color.secondary : Color.orange)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 4)
            Text("Requests routed from shed-host-agent when its approval mode is shed-desktop.")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .padding(.horizontal, 18).padding(.bottom, 12)

            if state.approvals.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(state.approvals) { item in
                            ApprovalCard(item: item, state: state)
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
            Image(systemName: "checkmark.shield").font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(state.hostAgentConnected ? "No pending approvals." : "Waiting for the host agent. Set its approval mode to shed-desktop.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ApprovalCard: View {
    let item: PendingApprovalItem
    @ObservedObject var state: AppState

    private var req: ApprovalRequest { item.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                NamespaceIcon(req.namespace)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(req.namespace) · \(req.op)").font(.system(size: 14, weight: .medium))
                    Text("shed \(req.qualifiedShed) · \(req.detail)").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                countdown
            }
            HStack(spacing: 8) {
                // The card applies the configured SSH policy — it notifies, it
                // doesn't change policy. The subtitle says what Approve will do.
                Text(approveEffect).font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button { state.onApprovalDecide?(req, item.denyChoice) } label: {
                    Text("Deny").font(.system(size: 13))
                }
                .buttonStyle(.bordered).tint(.red)
                Button {
                    state.onApprovalDecide?(req, item.approveChoice)
                } label: {
                    if item.gate.isBiometric {
                        // Fingerprint only when a biometric prompt will be shown.
                        Label("Approve (Touch ID)", systemImage: "touchid").font(.system(size: 13))
                    } else {
                        Text("Approve").font(.system(size: 13))
                    }
                }
                .buttonStyle(.borderedProminent).tint(.green)
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

    /// One line describing what Approve will do under the configured policy.
    private var approveEffect: String {
        switch item.defaultScope {
        case .perShed: return "Approve allows this shed until restart"
        case .perSession: return "Approve allows this shed for \(item.defaultTTL)"
        case .perRequest: return "Approve allows this request only"
        }
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, Int((req.expiresAtDate ?? context.date).timeIntervalSince(context.date)))
            Text("expires in \(remaining)s")
                .font(.system(size: 12))
                .foregroundStyle(remaining < 10 ? .red : .orange)
        }
    }
}

struct NamespaceIcon: View {
    let namespace: String
    init(_ namespace: String) { self.namespace = namespace }
    var body: some View {
        let color = Theme.namespaceColor(namespace)
        Image(systemName: Theme.namespaceSymbol(namespace))
            .frame(width: 32, height: 32)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
