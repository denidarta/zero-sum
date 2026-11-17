import SwiftUI
import ZeroSumKit

struct AccountsView: View {
    @EnvironmentObject var ledger: Ledger
    @State private var adding = false

    var body: some View {
        let balances = ledger.balances()
        NavigationStack {
            List(ledger.sorted(.account)) { account in
                NavigationLink {
                    TransactionsView(account: account.id)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(account.name)
                            if !account.bool("on_budget", default: true) {
                                Text("Tracking").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        AmountText(milliunits: balances[account.id] ?? 0)
                    }
                }
            }
            .overlay {
                if ledger.list(.account).isEmpty {
                    ContentUnavailableView(
                        "No accounts", systemImage: "building.columns",
                        description: Text("Add one with the plus button."))
                }
            }
            .navigationTitle("Accounts")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncBadge() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        adding = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add account")
                }
            }
            .sheet(isPresented: $adding) { AddAccountSheet() }
        }
    }
}

private struct AddAccountSheet: View {
    @EnvironmentObject var ledger: Ledger
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var onBudget = true

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Toggle("On budget", isOn: $onBudget)
            }
            .navigationTitle("New account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        ledger.run {
            try ledger.edit(
                .account, Ledger.newID(),
                [
                    "name": .string(name.trimmingCharacters(in: .whitespaces)),
                    "kind": .string(onBudget ? "checking" : "other"),
                    "on_budget": .bool(onBudget),
                ])
        }
        dismiss()
    }
}
