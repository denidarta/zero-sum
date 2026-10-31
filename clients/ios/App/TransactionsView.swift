import SwiftUI
import ZeroSumKit

/// Transactions of one account, or of all accounts when `account` is nil.
struct TransactionsView: View {
    @EnvironmentObject var ledger: Ledger
    let account: String?
    @State private var adding = false

    var body: some View {
        let accounts = ledger.names(.account)
        let payees = ledger.names(.payee)
        let categories = ledger.names(.category)
        let txs = ledger.list(.transaction)
            .filter { account == nil || $0.string("account_id") == account }
            .sorted { a, b in
                let (da, db) = (a.string("date") ?? "", b.string("date") ?? "")
                if da != db { return da > db }
                let (ta, tb) = (a.stamps["date"]?.ts ?? 0, b.stamps["date"]?.ts ?? 0)
                return ta != tb ? ta > tb : a.id < b.id
            }

        List {
            ForEach(txs) { t in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(payees[t.string("payee_id") ?? ""] ?? "—")
                        Text(categories[t.string("category_id") ?? ""] ?? "Income")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(subtitle(t, accounts))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    AmountText(milliunits: t.int("amount"), colored: true)
                }
            }
            .onDelete { offsets in
                let doomed = offsets.map { txs[$0] }
                ledger.run { for t in doomed { try ledger.remove(.transaction, t.id) } }
            }
        }
        .overlay {
            if accounts.isEmpty {
                ContentUnavailableView("Add an account to start", systemImage: "building.columns")
            } else if txs.isEmpty {
                ContentUnavailableView("No transactions", systemImage: "list.bullet")
            }
        }
        .navigationTitle(account.flatMap { accounts[$0] } ?? "All transactions")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { SyncBadge() }
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .disabled(accounts.isEmpty)
                    .accessibilityLabel("Add transaction")
            }
        }
        .sheet(isPresented: $adding) { AddTransactionSheet(account: account) }
    }

    private func subtitle(_ t: Entity, _ accounts: [String: String]) -> String {
        var parts = [t.string("date") ?? ""]
        if account == nil, let name = accounts[t.string("account_id") ?? ""] { parts.append(name) }
        if let memo = t.string("memo"), !memo.isEmpty { parts.append(memo) }
        return parts.joined(separator: " · ")
    }
}

private struct AddTransactionSheet: View {
    @EnvironmentObject var ledger: Ledger
    @Environment(\.dismiss) private var dismiss
    let account: String?

    @State private var date = Date()
    @State private var accountId = ""
    @State private var payee = ""
    @State private var categoryId = ""  // empty means income into Ready to Assign
    @State private var amount = ""
    @State private var inflow = false
    @State private var memo = ""

    var body: some View {
        let accounts = ledger.sorted(.account)
        let name = payee.trimmingCharacters(in: .whitespaces)
        let matches = ledger.list(.payee)
            .filter { $0.name.localizedCaseInsensitiveContains(name) && $0.name.lowercased() != name.lowercased() }
            .sorted { $0.name < $1.name }
        let suggestions: [Entity] = name.isEmpty ? [] : Array(matches.prefix(4))

        NavigationStack {
            Form {
                DatePicker("Date", selection: $date, displayedComponents: .date)
                if account == nil {
                    Picker("Account", selection: $accountId) {
                        ForEach(accounts) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    TextField("Payee", text: $payee)
                    ForEach(suggestions) { p in
                        Button(p.name) { payee = p.name }
                    }
                }
                Picker("Category", selection: $categoryId) {
                    Text("Income (Ready to Assign)").tag("")
                    ForEach(ledger.sorted(.category)) { Text($0.name).tag($0.id) }
                }
                TextField("Memo", text: $memo)
                TextField("Amount", text: $amount).keyboardType(.decimalPad)
                Toggle("Inflow", isOn: $inflow)
            }
            .navigationTitle("New transaction")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { save() }.disabled(Money.parse(amount) == nil || targetAccount(accounts) == nil)
                }
            }
            .onAppear { if accountId.isEmpty { accountId = accounts.first?.id ?? "" } }
        }
    }

    private func targetAccount(_ accounts: [Entity]) -> String? {
        account ?? (accountId.isEmpty ? accounts.first?.id : accountId)
    }

    private func save() {
        guard let value = Money.parse(amount), let acct = targetAccount(ledger.sorted(.account)) else { return }
        ledger.run {
            var payeeId: JSONValue = nil
            let name = payee.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                let hit = ledger.list(.payee).first { $0.name.lowercased() == name.lowercased() }
                let id = hit?.id ?? Ledger.newID()
                if hit == nil { try ledger.edit(.payee, id, ["name": .string(name)]) }
                payeeId = .string(id)
            }
            let memoText = memo.trimmingCharacters(in: .whitespaces)
            try ledger.edit(.transaction, Ledger.newID(), [
                "account_id": .string(acct),
                "date": .string(Money.dateString(date)),
                "amount": .int(inflow ? abs(value) : -abs(value)),
                "payee_id": payeeId,
                "category_id": categoryId.isEmpty ? .null : .string(categoryId),
                "memo": memoText.isEmpty ? .null : .string(memoText),
            ])
        }
        dismiss()
    }
}
