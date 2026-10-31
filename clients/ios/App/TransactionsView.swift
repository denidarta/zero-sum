import SwiftUI
import ZeroSumKit

/// Transactions of one account, or of all accounts when `account` is nil.
struct TransactionsView: View {
    @EnvironmentObject var ledger: Ledger
    let account: String?
    @State private var form: FormTarget?
    @State private var deletingTransfer: Entity?

    private enum FormTarget: Identifiable {
        case add
        case edit(Entity)

        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let t): return t.id
            }
        }
    }

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
                Button { form = .edit(t) } label: {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(t, payees, accounts))
                            Text(categoryLabel(t, categories))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(subtitle(t, accounts))
                                .font(.caption2).foregroundStyle(.secondary)
                            if ledger.isUnmatched(t) {
                                Text("Unmatched transfer: the other side was deleted.")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        if t.bool("cleared") {
                            Image(systemName: "checkmark.circle").foregroundStyle(.secondary)
                                .accessibilityLabel("Cleared")
                        }
                        AmountText(milliunits: t.int("amount"), colored: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) {
                        if t.isTransfer { deletingTransfer = t } else { remove(t) }
                    } label: { Label("Delete", systemImage: "trash") }
                }
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
                Button { form = .add } label: { Image(systemName: "plus") }
                    .disabled(accounts.isEmpty)
                    .accessibilityLabel("Add transaction")
            }
        }
        .sheet(item: $form) { target in
            switch target {
            case .add: TransactionForm(account: account, editing: nil)
            case .edit(let t): TransactionForm(account: account, editing: t)
            }
        }
        .confirmationDialog(
            "Delete both legs of this transfer?",
            isPresented: Binding(get: { deletingTransfer != nil }, set: { if !$0 { deletingTransfer = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete transfer", role: .destructive) {
                if let t = deletingTransfer { remove(t) }
            }
        }
    }

    private func remove(_ t: Entity) {
        ledger.run { try ledger.removeTransaction(t) }
    }

    private func title(_ t: Entity, _ payees: [String: String], _ accounts: [String: String]) -> String {
        guard t.isTransfer else { return payees[t.string("payee_id") ?? ""] ?? "—" }
        let other = accounts[t.string("transfer_account_id") ?? ""] ?? "—"
        return t.int("amount") < 0 ? "Transfer to \(other)" : "Transfer from \(other)"
    }

    private func categoryLabel(_ t: Entity, _ categories: [String: String]) -> String {
        let lines = t.splits
        if !lines.isEmpty { return "Split (\(lines.count))" }
        let name = categories[t.string("category_id") ?? ""]
        return t.isTransfer ? (name ?? "Transfer") : (name ?? "Income")
    }

    private func subtitle(_ t: Entity, _ accounts: [String: String]) -> String {
        var parts = [t.string("date") ?? ""]
        if account == nil, let name = accounts[t.string("account_id") ?? ""] { parts.append(name) }
        if let memo = t.string("memo"), !memo.isEmpty { parts.append(memo) }
        return parts.joined(separator: " · ")
    }
}

/// Add a transaction or transfer, or edit an existing one.
private struct TransactionForm: View {
    @EnvironmentObject var ledger: Ledger
    @Environment(\.dismiss) private var dismiss
    /// Account the list is scoped to. New transactions go there.
    let account: String?
    let editing: Entity?

    private enum Mode: String { case transaction = "Transaction", transfer = "Transfer" }

    private struct Line: Identifiable {
        let id = UUID()
        var category = ""
        var amount = ""
    }

    @State private var loaded = false
    @State private var mode = Mode.transaction
    @State private var date = Date()
    @State private var accountId = ""
    @State private var toId = ""
    @State private var payee = ""
    @State private var categoryId = ""  // empty means income into Ready to Assign
    @State private var amount = ""
    @State private var inflow = false
    @State private var cleared = false
    @State private var memo = ""
    @State private var split = false
    @State private var lines = [Line()]
    @State private var error = ""

    private var editingTransfer: Bool { editing?.isTransfer ?? false }

    var body: some View {
        let accounts = ledger.sorted(.account)
        let name = payee.trimmingCharacters(in: .whitespaces)
        let matches = ledger.list(.payee)
            .filter { $0.name.localizedCaseInsensitiveContains(name) && $0.name.lowercased() != name.lowercased() }
            .sorted { $0.name < $1.name }
        let suggestions: [Entity] = name.isEmpty ? [] : Array(matches.prefix(4))
        let categories = ledger.sorted(.category)
        let (from, to) = transferEnds()
        let needsCategory = mode == .transfer && !from.isEmpty && !to.isEmpty && ledger.transferNeedsCategory(from: from, to: to)
        let total = Money.parse(amount).map { abs($0) } ?? 0
        let lineSum = lines.reduce(Int64(0)) { $0 + abs(Money.parse($1.amount) ?? 0) }

        NavigationStack {
            Form {
                if editing == nil {
                    Picker("Type", selection: $mode) {
                        Text("Transaction").tag(Mode.transaction)
                        Text("Transfer").tag(Mode.transfer)
                    }
                    .pickerStyle(.segmented)
                }
                DatePicker("Date", selection: $date, displayedComponents: .date)

                if mode == .transaction {
                    if account == nil || editing != nil {
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
                    if !split {
                        Picker("Category", selection: $categoryId) {
                            Text("Income (Ready to Assign)").tag("")
                            ForEach(categories) { Text($0.name).tag($0.id) }
                        }
                    }
                    Toggle("Split", isOn: $split)
                } else {
                    // An existing pair keeps its accounts (D8): delete and recreate to change them.
                    if editingTransfer {
                        LabeledContent("From", value: ledger.names(.account)[from] ?? "—")
                        LabeledContent("To", value: ledger.names(.account)[to] ?? "—")
                    } else {
                        Picker("From", selection: $accountId) {
                            ForEach(accounts) { Text($0.name).tag($0.id) }
                        }
                        Picker("To", selection: $toId) {
                            ForEach(accounts) { Text($0.name).tag($0.id) }
                        }
                    }
                    if needsCategory {
                        Picker("Category", selection: $categoryId) {
                            Text("Choose… (required)").tag("")
                            ForEach(categories) { Text($0.name).tag($0.id) }
                        }
                    }
                }

                TextField("Memo", text: $memo)
                TextField("Amount", text: $amount).keyboardType(.decimalPad)
                if mode == .transaction { Toggle("Inflow", isOn: $inflow) }
                Toggle("Cleared", isOn: $cleared)

                if mode == .transaction && split {
                    Section {
                        ForEach($lines) { $line in
                            HStack {
                                Picker("Category", selection: $line.category) {
                                    Text("Category").tag("")
                                    ForEach(categories) { Text($0.name).tag($0.id) }
                                }
                                .labelsHidden()
                                TextField("Amount", text: $line.amount)
                                    .keyboardType(.decimalPad)
                                    .multilineTextAlignment(.trailing)
                                    .frame(maxWidth: 110)
                                if lines.count > 1 {
                                    Button { lines.removeAll { $0.id == line.id } } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Remove split line")
                                }
                            }
                        }
                        Button("Add split line") { lines.append(Line()) }
                    } header: {
                        Text("Split lines")
                    } footer: {
                        Text("Left to split: \(Money.format(total - lineSum))")
                    }
                }

                if !error.isEmpty {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle(editing == nil ? "New \(mode.rawValue.lowercased())" : "Edit \(mode.rawValue.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editing == nil ? "Add" : "Save") { save(from: from, to: to, needsCategory: needsCategory) }
                        .disabled(Money.parse(amount) == nil)
                }
            }
            .onAppear(perform: load)
        }
    }

    /// Outflow and inflow accounts of a transfer. For an edited leg the direction is fixed.
    private func transferEnds() -> (from: String, to: String) {
        if let t = editing, t.isTransfer {
            let (own, other) = (t.string("account_id") ?? "", t.string("transfer_account_id") ?? "")
            return t.int("amount") < 0 ? (own, other) : (other, own)
        }
        return (accountId, toId)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        let accounts = ledger.sorted(.account)
        // Default to an on-budget account: that is where most transactions go.
        let first = account ?? (accounts.first { $0.bool("on_budget", default: true) } ?? accounts.first)?.id ?? ""
        accountId = first
        toId = accounts.first { $0.id != first }?.id ?? ""
        guard let t = editing else { return }
        mode = t.isTransfer ? .transfer : .transaction
        date = Money.date(from: t.string("date") ?? "") ?? Date()
        accountId = t.string("account_id") ?? first
        payee = t.string("payee_id").flatMap { ledger.get(.payee, $0)?.name } ?? ""
        categoryId = t.string("category_id") ?? ""
        memo = t.string("memo") ?? ""
        amount = Money.format(abs(t.int("amount")))
        inflow = t.int("amount") >= 0
        cleared = t.bool("cleared")
        split = !t.splits.isEmpty
        if split {
            lines = t.splits.map { Line(category: $0.categoryId, amount: Money.format(abs($0.amount))) }
        }
    }

    private func save(from: String, to: String, needsCategory: Bool) {
        error = ""
        guard let value = Money.parse(amount) else { return }
        let magnitude = abs(value)
        let memoText = memo.trimmingCharacters(in: .whitespaces)
        let dateText = Money.dateString(date)
        do {
            if mode == .transfer {
                guard !from.isEmpty, !to.isEmpty, from != to else { return error = "Pick two different accounts." }
                guard magnitude != 0 else { return error = "A transfer needs an amount." }
                guard !needsCategory || !categoryId.isEmpty else { return error = "Pick the category this money comes from." }
                let category = needsCategory ? categoryId : nil
                if let t = editing {
                    try ledger.editTransfer(t, date: dateText, amount: magnitude, memo: memoText.isEmpty ? nil : memoText, cleared: cleared, categoryId: category)
                } else {
                    try ledger.addTransfer(date: dateText, from: from, to: to, amount: magnitude, memo: memoText.isEmpty ? nil : memoText, cleared: cleared, categoryId: category)
                }
                return dismiss()
            }

            guard !accountId.isEmpty else { return error = "Pick an account." }
            var splitLines: [SplitLine] = []
            if split {
                let values = lines.map { Money.parse($0.amount) }
                guard !lines.enumerated().contains(where: { $1.category.isEmpty || (values[$0] ?? 0) == 0 }) else {
                    return error = "Every split line needs a category and an amount."
                }
                let sum = values.reduce(Int64(0)) { $0 + abs($1 ?? 0) }
                guard sum == magnitude else {
                    return error = "Split lines add up to \(Money.format(sum)), but the amount is \(Money.format(magnitude))."
                }
                splitLines = lines.enumerated().map { i, l in
                    SplitLine(categoryId: l.category, amount: inflow ? abs(values[i]!) : -abs(values[i]!))
                }
            }

            var payeeId: JSONValue = .null
            let name = payee.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty {
                let hit = ledger.list(.payee).first { $0.name.lowercased() == name.lowercased() }
                let id = hit?.id ?? Ledger.newID()
                if hit == nil { try ledger.edit(.payee, id, ["name": .string(name)]) }
                payeeId = .string(id)
            }
            let fields: [String: JSONValue] = [
                "account_id": .string(accountId),
                "date": .string(dateText),
                "amount": .int(inflow ? magnitude : -magnitude),
                "payee_id": payeeId,
                "category_id": split || categoryId.isEmpty ? .null : .string(categoryId),
                "memo": memoText.isEmpty ? .null : .string(memoText),
                "cleared": .bool(cleared),
            ]
            if let t = editing {
                try ledger.updateTransaction(t, fields: fields, splits: splitLines)
            } else {
                var all = fields
                if split { all["splits"] = .array(splitLines.map(\.json)) }
                try ledger.edit(.transaction, Ledger.newID(), all)
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
