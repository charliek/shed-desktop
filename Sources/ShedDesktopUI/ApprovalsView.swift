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
    @State private var decision: CardDecision
    @State private var ttl: String

    init(item: PendingApprovalItem, state: AppState) {
        self.item = item
        self.state = state
        _decision = State(initialValue: CardDecision(defaultScope: item.defaultScope))
        _ttl = State(initialValue: item.defaultTTL)
    }

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
                // One dropdown, most → least permissive. Duration shows for Time Based only.
                Picker("", selection: $decision) {
                    ForEach(CardDecision.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(maxWidth: 190)
                if decision.usesDuration {
                    Text("for").font(.system(size: 12)).foregroundStyle(.secondary)
                    TextField("", text: $ttl, prompt: Text("2h")).frame(width: 54)
                }
                Spacer()
                Button { state.onApprovalDecide?(req, decision.choice(ttl: ttl)) } label: {
                    if decision.isDeny {
                        Label("Deny", systemImage: "xmark").font(.system(size: 13))
                    } else if item.gate.isBiometric {
                        // Fingerprint only when a biometric prompt will be shown.
                        Label("Approve (Touch ID)", systemImage: "touchid").font(.system(size: 13))
                    } else {
                        Text("Approve").font(.system(size: 13))
                    }
                }
                .buttonStyle(.borderedProminent).tint(decision.isDeny ? .red : .green)
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
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
