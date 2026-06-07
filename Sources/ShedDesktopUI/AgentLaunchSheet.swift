// AgentLaunchSheet.swift — launch a remote-control session into a shed (M2),
// presented as a centered modal card (see DashboardView's modalOverlay).

import ShedKit
import SwiftUI

public struct AgentLaunchSheet: View {
    @ObservedObject var state: AppState

    @State private var target: String = ""  // shed id "host/name"
    @State private var kind: RcKind = .default
    @State private var displayName: String = ""

    public init(state: AppState) {
        self.state = state
    }

    private var runningSheds: [Shed] {
        state.sheds.filter { $0.status == .running }
    }

    public var body: some View {
        VStack(spacing: 0) {
            SheetHeader(icon: "wand.and.stars", title: "Launch agent",
                        subtitle: "Start a remote-control session inside a shed.", onClose: close)
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                SheetField("Shed") {
                    SheetDropdown(current: shedDisplay) {
                        ForEach(runningSheds) { s in
                            Button("\(s.host)/\(s.name)") { target = s.id }
                        }
                    }
                }
                SheetField("Kind") {
                    SheetDropdown(current: kind.rawValue) {
                        ForEach(RcKind.allCases, id: \.self) { k in
                            Button(k.rawValue) { kind = k }
                        }
                    }
                }
                SheetField("Display name", hint: "optional") {
                    SheetTextField(placeholder: "e.g. nightly-refactor", text: $displayName)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 18)
            Divider()
            HStack {
                SheetCancelButton(action: close)
                Spacer()
                SheetPrimaryButton(title: "Launch", icon: "sparkles",
                                   tint: Theme.approve, fg: Theme.approveFg,
                                   disabled: target.isEmpty, action: launch)
            }
            .padding(16)
        }
        .modalCard()
        .onAppear { if target.isEmpty { target = runningSheds.first?.id ?? "" } }
    }

    private var shedDisplay: String {
        runningSheds.first(where: { $0.id == target }).map { "\($0.host)/\($0.name)" } ?? "—"
    }

    private func close() { state.showLaunchSheet = false }

    private func launch() {
        guard let shed = runningSheds.first(where: { $0.id == target }) else { return }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        state.onRcLaunch?(shed.host, shed.name, kind, name.isEmpty ? nil : name)
        close()
    }
}
