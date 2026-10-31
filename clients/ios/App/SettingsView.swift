import SwiftUI
import ZeroSumKit

struct SettingsView: View {
    @EnvironmentObject var ledger: Ledger
    @State private var url = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://mac-mini.tailnet.ts.net", text: $url)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit { ledger.setServer(url) }
                    Button("Save and sync") { ledger.setServer(url) }
                } header: {
                    Text("Server")
                } footer: {
                    Text("The tailscale serve address of the Mac mini. Tailscale must be connected on this phone.")
                }
                Section("Sync") {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(SyncBadge.label(ledger.state, pending: ledger.outbox.count))
                            .foregroundStyle(.secondary)
                    }
                    Button("Sync now") { Task { await ledger.sync() } }
                }
                Section("This device") {
                    Text(ledger.deviceId).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Settings")
            .onAppear { url = ledger.serverURL }
        }
    }
}
