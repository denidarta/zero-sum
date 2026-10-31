import SwiftUI
import ZeroSumKit

struct BudgetView: View {
    @EnvironmentObject var ledger: Ledger
    @State private var month = Money.thisMonth()
    @State private var assigning: Entity?
    @State private var addingGroup = false
    @State private var addingCategoryTo: Entity?
    @State private var deletingGroup: Entity?
    @State private var newName = ""

    var body: some View {
        let budget = ledger.budget(month: month)
        let rows = Dictionary(budget.categories.map { ($0.categoryId, $0) }, uniquingKeysWith: { a, _ in a })
        let categories = ledger.sorted(.category)

        NavigationStack {
            List {
                Section {
                    HStack {
                        Button { month = Money.shiftMonth(month, by: -1) } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Previous month")
                        Spacer()
                        Text(Money.monthTitle(month)).font(.headline)
                        Spacer()
                        Button { month = Money.shiftMonth(month, by: 1) } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel("Next month")
                    }
                    .buttonStyle(.borderless)
                    HStack {
                        Text("Ready to Assign")
                        Spacer()
                        Text(Money.format(budget.readyToAssign))
                            .monospacedDigit().bold()
                            .foregroundStyle(budget.readyToAssign < 0 ? Color.red : Color.green)
                    }
                }

                ForEach(ledger.sorted(.categoryGroup)) { group in
                    Section {
                        ForEach(categories.filter { $0.string("group_id") == group.id }) { cat in
                            Button { assigning = cat } label: {
                                CategoryRow(name: cat.name, row: rows[cat.id])
                            }
                            .buttonStyle(.plain)
                        }
                        Button("Add category") {
                            newName = ""
                            addingCategoryTo = group
                        }
                    } header: {
                        HStack {
                            Text(group.name)
                            Spacer()
                            Button(role: .destructive) { deletingGroup = group } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Delete group \(group.name)")
                        }
                    }
                }
            }
            .navigationTitle("Budget")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { SyncBadge() }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = ""; addingGroup = true } label: { Image(systemName: "folder.badge.plus") }
                        .accessibilityLabel("Add category group")
                }
            }
            .sheet(item: $assigning) { cat in
                AssignSheet(category: cat, month: month, current: rows[cat.id]?.assigned ?? 0)
            }
            .alert("New category group", isPresented: $addingGroup) {
                TextField("Name", text: $newName)
                Button("Add") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty {
                        ledger.run {
                            try ledger.edit(.categoryGroup, Ledger.newID(), [
                                "name": .string(name), "sort": .int(Int64(ledger.list(.categoryGroup).count)),
                            ])
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .alert(
                "New category", isPresented: Binding(get: { addingCategoryTo != nil }, set: { if !$0 { addingCategoryTo = nil } })
            ) {
                TextField("Name", text: $newName)
                Button("Add") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty, let group = addingCategoryTo {
                        ledger.run {
                            try ledger.edit(.category, Ledger.newID(), ["group_id": .string(group.id), "name": .string(name)])
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete group \(deletingGroup?.name ?? "")?",
                isPresented: Binding(get: { deletingGroup != nil }, set: { if !$0 { deletingGroup = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete group", role: .destructive) {
                    if let g = deletingGroup { ledger.run { try ledger.remove(.categoryGroup, g.id) } }
                }
            }
        }
    }
}

private struct CategoryRow: View {
    let name: String
    let row: CategoryMonth?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Spacer()
                Text(Money.format(row?.available ?? 0))
                    .monospacedDigit().bold()
                    .foregroundStyle((row?.available ?? 0) < 0 ? Color.red : Color.primary)
            }
            HStack(spacing: 16) {
                Text("Assigned \(Money.format(row?.assigned ?? 0))")
                Text("Activity \(Money.format(row?.activity ?? 0))")
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private struct AssignSheet: View {
    @EnvironmentObject var ledger: Ledger
    @Environment(\.dismiss) private var dismiss
    let category: Entity
    let month: String
    let current: Int64
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Assigned in \(Money.monthTitle(month))") {
                    TextField("Amount", text: $text)
                        .keyboardType(.decimalPad)
                }
            }
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(Money.parse(text) == nil)
                }
            }
            .onAppear { text = Money.format(current).replacingOccurrences(of: ",", with: "") }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let value = Money.parse(text) else { return }
        if value != current {
            ledger.run {
                try ledger.edit(.budgetEntry, ledger.entryId(category: category.id, month: month), [
                    "category_id": .string(category.id), "month": .string(month), "assigned": .int(value),
                ])
            }
        }
        dismiss()
    }
}
