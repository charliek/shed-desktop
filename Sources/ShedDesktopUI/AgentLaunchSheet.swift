// AgentLaunchSheet.swift — launch a remote-control session into a shed (M2).

import ShedKit
import SwiftUI

public struct AgentLaunchSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

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
        VStack(alignment: .leading, spacing: 0) {
            Text("Launch agent").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text).padding(16)
            Divider()
            Form {
                Picker("Shed", selection: $target) {
                    ForEach(runningSheds) { Text("\($0.host)/\($0.name)").tag($0.id) }
                }
                Picker("Kind", selection: $kind) {
                    ForEach(RcKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextField("Display name (optional)", text: $displayName).textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .listRowBackground(Theme.surface)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Launch") { launch() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(target.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420, height: 300)
        .background(Theme.bg)
        .onAppear { if target.isEmpty { target = runningSheds.first?.id ?? "" } }
    }

    private func launch() {
        guard let shed = runningSheds.first(where: { $0.id == target }) else { return }
        let name = displayName.trimmingCharacters(in: .whitespaces)
        state.onRcLaunch?(shed.host, shed.name, kind, name.isEmpty ? nil : name)
        dismiss()
    }
}
