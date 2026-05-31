// PreferencesView.swift — the preferences window content (M4).

import ShedKit
import SwiftUI

public struct PreferencesView: View {
    @ObservedObject var prefs: Preferences
    @ObservedObject var state: AppState

    public init(prefs: Preferences, state: AppState) {
        self.prefs = prefs
        self.state = state
    }

    public var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $prefs.launchAtLogin)
                    .onChange(of: prefs.launchAtLogin) { _, v in prefs.onLaunchAtLogin?(v) }
            }

            Section("Terminal") {
                TextField("Command template", text: $prefs.terminalTemplate, prompt: Text("ghostty -e {cmd}"))
                    .onChange(of: prefs.terminalTemplate) { _, v in prefs.onTerminalTemplate?(v) }
                Text("`{cmd}` is replaced with the ssh command. Leave empty to use Terminal.app.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Approval policy") {
                Picker("Default mode", selection: $prefs.defaultApprovalMode) {
                    ForEach(ApprovalMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .onChange(of: prefs.defaultApprovalMode) { _, v in prefs.onDefaultMode?(v) }
                Text("How shed-desktop responds when the host agent delegates a credential request.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            Section("Hosts") {
                if state.hosts.isEmpty {
                    Text("No hosts in ~/.shed/config.yaml").foregroundStyle(.secondary)
                } else {
                    ForEach(state.hosts, id: \.name) { host in
                        HStack(spacing: 8) {
                            Circle().fill(host.reachable ? Color.green : Color.secondary).frame(width: 7, height: 7)
                            Text(host.name)
                            Spacer()
                            Text("\(host.host):\(host.httpPort)").foregroundStyle(.secondary).font(.system(size: 11))
                        }
                    }
                    Text("Read-only — manage hosts with the shed CLI.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 460)
    }
}
