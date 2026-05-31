// CreateShedSheet.swift — the create-shed flow with live SSE progress (M1).
//
// Free-text `owner/repo` for v1 (a gh-backed picker is a later fast-follow).

import ShedKit
import SwiftUI

public struct CreateShedSheet: View {
    @ObservedObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var host: String = ""
    @State private var name: String = ""
    @State private var repo: String = ""
    @State private var backend: String = "auto"
    @State private var cpus: String = ""
    @State private var memoryMB: String = ""
    @State private var provision = true
    @State private var submitted = false

    public init(state: AppState) {
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("New shed").font(.system(size: 15, weight: .semibold)).padding(16)
            Divider()
            if submitted {
                progress
            } else {
                form
            }
        }
        .frame(width: 460, height: 420)
        .onAppear { if host.isEmpty { host = state.hosts.first?.name ?? "" } }
    }

    private var form: some View {
        VStack(spacing: 0) {
            Form {
                Picker("Host", selection: $host) {
                    ForEach(state.hosts, id: \.name) { Text($0.name).tag($0.name) }
                }
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Repo (owner/repo, optional)", text: $repo).textFieldStyle(.roundedBorder)
                Picker("Backend", selection: $backend) {
                    Text("auto").tag("auto")
                    Text("vz").tag("vz")
                    Text("firecracker").tag("firecracker")
                }
                HStack {
                    TextField("CPUs", text: $cpus).textFieldStyle(.roundedBorder).frame(width: 80)
                    TextField("Memory (MB)", text: $memoryMB).textFieldStyle(.roundedBorder).frame(width: 120)
                }
                Toggle("Provision", isOn: $provision)
            }
            .formStyle(.grouped)
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Create") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || host.isEmpty)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var progress: some View {
        let create = state.activeCreate
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if create?.state == .progress { ProgressView().controlSize(.small) }
                Text(statusText(create)).font(.system(size: 13, weight: .medium))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array((create?.messages ?? []).enumerated()), id: \.offset) { _, msg in
                        Text(msg).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    if let err = create?.error {
                        Text(err).font(.system(size: 12, design: .monospaced)).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            HStack {
                Spacer()
                Button(create?.state == .progress ? "Hide" : "Done") {
                    state.activeCreate = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    private func statusText(_ create: CreateProgress?) -> String {
        switch create?.state {
        case .complete: return "Created \(create?.shed?.name ?? name)"
        case .error: return "Create failed"
        default: return "Creating \(name)…"
        }
    }

    private func submit() {
        let request = CreateShedRequest(
            name: name.trimmingCharacters(in: .whitespaces),
            repo: repo.isEmpty ? nil : repo,
            backend: backend == "auto" ? nil : backend,
            cpus: Int(cpus),
            memoryMB: Int(memoryMB),
            noProvision: provision ? nil : true)
        submitted = true
        state.onCreate?(host, request)
    }
}
