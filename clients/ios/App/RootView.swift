import SwiftUI
import ZeroSumKit

struct RootView: View {
    @EnvironmentObject var ledger: Ledger

    var body: some View {
        TabView {
            BudgetView()
                .tabItem { Label("Budget", systemImage: "chart.pie") }
            NavigationStack { TransactionsView(account: nil) }
                .tabItem { Label("Transactions", systemImage: "list.bullet") }
            AccountsView()
                .tabItem { Label("Accounts", systemImage: "building.columns") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .alert(
            "Could not save",
            isPresented: Binding(
                get: { ledger.lastError != nil },
                set: { if !$0 { ledger.lastError = nil } }),
            presenting: ledger.lastError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }
}

/// Small sync indicator for toolbars.
struct SyncBadge: View {
    @EnvironmentObject var ledger: Ledger

    var body: some View {
        HStack(spacing: 4) {
            switch ledger.state {
            case .syncing: ProgressView().controlSize(.small)
            case .idle: Image(systemName: "checkmark.icloud")
            case .offline: Image(systemName: "icloud.slash")
            case .unconfigured: Image(systemName: "exclamationmark.icloud")
            }
            if !ledger.outbox.isEmpty { Text("\(ledger.outbox.count)").font(.caption) }
        }
        .foregroundStyle(ledger.state == .idle || ledger.state == .syncing ? Color.secondary : Color.orange)
        .accessibilityLabel(SyncBadge.label(ledger.state, pending: ledger.outbox.count))
    }

    static func label(_ state: SyncState, pending: Int) -> String {
        let base: String
        switch state {
        case .idle: base = "Synced"
        case .syncing: base = "Syncing…"
        case .offline: base = "Offline"
        case .unconfigured: base = "No server set"
        }
        return pending > 0 ? "\(base) · \(pending) pending" : base
    }
}

struct AmountText: View {
    let milliunits: Int64
    var colored = false

    var body: some View {
        Text(Money.format(milliunits))
            .monospacedDigit()
            .foregroundStyle(colored ? (milliunits < 0 ? Color.red : Color.green) : Color.primary)
    }
}
