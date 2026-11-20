import SwiftUI

struct DailyRoutineView: View {
  @EnvironmentObject private var store: Store
  @Environment(\.locale) private var locale
  let summary: Summary
  @State private var adding = false
  @State private var draft = ""
  @State private var draftInvalid = false
  @State private var draftArmed = false
  @State private var pendingDelete: RoutineChecklistItem?
  @FocusState private var draftFocused: Bool
  private var items: [RoutineChecklistItem] { summary.routine_today?.items ?? [] }
  private var checked: Int { items.filter(\.completed).count }
  var body: some View {
    let _ = locale
    CanvasSection(
      title: "Daily routine",
      detail: items.isEmpty ? nil : L("%d of %d", checked, items.count),
      accessory: AnyView(addButton)
    ) {
      VStack(alignment: .leading, spacing: 8) {
        if items.isEmpty && !adding {
          HStack(spacing: 6) {
            Text("Small steps, every day").font(.system(size: 13, weight: .medium))
            HintButton(text: "Create a checklist that contributes to your discipline.")
          }
        }
        ForEach(items) { item in
          row(item)
        }
        if adding {
          TextField(L("New task"), text: $draft)
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .focused($draftFocused)
            .onSubmit { commitDraft() }
            .onExitCommand {
              adding = false
              draft = ""
              draftInvalid = false
              draftArmed = false
            }
            .onChange(of: draft) { _ in draftInvalid = false }
            .onChange(of: draftFocused) { focused in
              if focused {
                draftArmed = true
              } else if draftArmed {
                commitDraft()
              }
            }
          if draftInvalid {
            Text("Use unique names, up to 100 characters each.")
              .font(.system(size: 11)).foregroundStyle(AppStyle.amber)
          }
        }
      }
      .frame(maxWidth: .infinity, alignment: .topLeading)
      .confirmationDialog(
        Text(pendingDelete.map { L("Remove %@ from the routine?", $0.title) } ?? ""),
        isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
        titleVisibility: .visible
      ) {
        Button("Delete", role: .destructive) {
          if let id = pendingDelete?.id { remove(id) }
          pendingDelete = nil
        }
        Button("Cancel", role: .cancel) { pendingDelete = nil }
      } message: {
        Text("This task leaves the routine. Past days keep their own marks.")
      }
    }
  }
  private var addButton: some View {
    Button {
      adding = true
      draftFocused = true
    } label: {
      Image(systemName: "plus")
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 22, height: 22)
    }
    .buttonStyle(.borderless)
    .disabled(store.busy || adding || items.count >= RoutineDraft.maxItems)
    .accessibilityLabel("Add item")
    .help("Add item")
  }
  private func row(_ item: RoutineChecklistItem) -> some View {
    HStack(alignment: .center, spacing: 8) {
      Text(item.title)
        .font(.system(size: 13))
        .foregroundStyle(item.completed ? Color.secondary : Color.primary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
          Button(role: .destructive) { pendingDelete = item } label: {
            Label("Delete", systemImage: "trash")
          }
          .disabled(store.busy)
        }
      Toggle(isOn: Binding(get: { item.completed }, set: { value in
        guard let day = summary.routine_today?.day else { return }
        store.send("routine_check", ["day": day, "id": item.id, "completed": value])
      })) { Text(verbatim: "") }
        .toggleStyle(.checkbox)
        .labelsHidden()
        .fixedSize()
        .disabled(store.busy)
        .accessibilityLabel(item.title)
    }
    .accessibilityAction(named: Text("Remove routine item")) { pendingDelete = item }
  }
  private func remove(_ id: String) {
    let titles = items.filter { $0.id != id }.map(\.title)
    store.send(
      "set_routine",
      ["items": titles, "enabled": !titles.isEmpty])
  }
  private func commitDraft() {
    guard adding else { return }
    let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else {
      adding = false
      draft = ""
      draftInvalid = false
      draftArmed = false
      return
    }
    let names = items.map(\.title) + [title]
    guard names.count <= RoutineDraft.maxItems, title.unicodeScalars.count <= 100,
      Set(names.map { $0.lowercased() }).count == names.count
    else {
      draftInvalid = true
      draftFocused = true
      return
    }
    adding = false
    draft = ""
    draftInvalid = false
    draftArmed = false
    store.send("set_routine", ["items": names, "enabled": true])
  }
}


struct RoutineDraftList: View {
  @Environment(\.locale) private var locale
  @Binding var rows: [RoutineDraftItem]
  var body: some View {
    let _ = locale
    VStack(alignment: .leading, spacing: 10) {
      ForEach($rows) { $row in
        HStack(spacing: 10) {
          TextField(placeholder(row.id), text: $row.title)
            .textFieldStyle(.roundedBorder).controlSize(.large).labelsHidden().multilineTextAlignment(.leading)
            .accessibilityLabel(L("Routine item %d", (rows.firstIndex { $0.id == row.id } ?? 0) + 1))
          Button {
            let id = row.id
            rows.removeAll { $0.id == id }
          } label: {
            Image(systemName: "minus.circle").font(.system(size: 15)).foregroundStyle(.secondary)
          }.buttonStyle(.borderless).disabled(rows.count <= 1)
            .help("Remove routine item").accessibilityLabel("Remove routine item")
        }
      }
      Button { rows.append(RoutineDraftItem()) } label: {
        Label("Add item", systemImage: "plus")
      }.buttonStyle(.borderless).disabled(rows.count >= RoutineDraft.maxItems).padding(.top, 2)
    }
  }
  private func placeholder(_ id: UUID) -> String {
    let index = rows.firstIndex { $0.id == id } ?? 0
    return L(["e.g. Plan the day", "e.g. Read for 15 minutes", "e.g. Tidy the desk"][index % 3])
  }
}
