import SwiftUI

struct QuestTreeView: View {
  @EnvironmentObject private var store: Store
  @Environment(\.locale) private var locale
  let skill: Skill
  let state: GameState
  let summary: Summary
  @Binding var search: String
  let searchSubmission: UUID
  private let scope: QuestTreeScope
  private let index: [String: Quest]
  private let fulfilled: Set<String>
  private let unlocked: Set<String>
  private let practice: [String: QuestPractice]
  private let layoutKey: String
  @State private var cache = SkillTreeLayoutCache()
  @State private var selected: String?
  @State private var stepsOpen = false
  @State private var focusRequest = UUID()
  private var layout: SkillTreeLayout { cache.layout(quests: scope.quests, key: layoutKey) }
  private var quest: Quest? { index[selected ?? ""] ?? scope.members.first }
  private var done: Int { scope.members.filter { fulfilled.contains($0.id) }.count }
  private var canVerify: Bool { state.canVerifySkill(skill.id, summary: summary) && !store.busy }

  init(skill: Skill, state: GameState, summary: Summary, search: Binding<String>, searchSubmission: UUID) {
    self.skill = skill
    self.state = state
    self.summary = summary
    _search = search
    self.searchSubmission = searchSubmission
    scope = QuestTreeScope(skillID: skill.id, quests: state.quests)
    index = Dictionary(state.quests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    fulfilled = state.fulfilledQuestIDs
    unlocked = Set(summary.unlocked_quests)
    practice = QuestPractice.totals(state.sessions)
    layoutKey = "quests|" + SkillTreeLayout.signature(scope.quests)
  }
  var body: some View {
    let _ = locale
    PageFrame {
      VStack(spacing: 16) {
        header
        if scope.members.isEmpty {
          EmptyState(
            symbol: "point.3.filled.connected.trianglepath.dotted",
            title: "Build this skill one quest at a time",
            message: "Add a first quest, then connect the next steps through dependencies.",
            buttonTitle: "Create a quest"
          ) { store.newQuest(skillID: skill.id) }
          .frame(maxHeight: .infinity, alignment: .top)
        } else {
          HStack(alignment: .top, spacing: 0) {
            graph
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            inspector.frame(width: 280)
          }
        }
      }
      .padding(.horizontal, 20)
      .padding(.bottom, 16)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .onAppear(perform: normalizeSelection)
    .onChange(of: layoutKey) { _ in normalizeSelection() }
    .onChange(of: selected) { _ in stepsOpen = false }
  }
  private func normalizeSelection() {
    let next = scope.selection(retaining: selected, fulfilled: fulfilled, unlocked: unlocked)
    if next != selected {
      selected = next
      focusRequest = UUID()
    }
  }

  private func reveal(_ id: String) {
    selected = id
    focusRequest = UUID()
  }
  private func status(_ quest: Quest) -> QuestTreeStatus {
    if state.active?.quest_id == quest.id { return .active }
    if fulfilled.contains(quest.id) { return .done }
    if quest.status == "Cancelled" { return .cancelled }
    if quest.status == "Missed" { return .missed }
    if !unlocked.contains(quest.id) { return .locked }
    if quest.status == "Paused" { return .paused }
    if quest.status == "Active" { return .active }
    return .available
  }
  private var header: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Text(skill.displayTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 8)
        Button {
          store.sheet = .mastery(skill.id)
        } label: {
          Label("Verify mastery…", systemImage: "checkmark.seal")
        }.buttonStyle(.borderedProminent).disabled(!canVerify)
      }
      HStack {
        Text(L("%d / %d quests completed", done, scope.members.count))
          .font(.system(size: 12, weight: .medium))
        Spacer()
        if !summary.unlocked_skills.contains(skill.id) {
          HintButton(text: "Complete the parent skill requirements first.")
        } else if !state.skillQuestsCompleted(skill.id) {
          HintButton(text: "Complete all quests to verify this skill.")
        }
      }
      ProgressTrack(
        value: scope.members.isEmpty ? 0 : Double(done) / Double(scope.members.count) * 100)
    }
    .padding(.horizontal, 18)
    .padding(.top, 12)
  }
  private var graph: some View {
    DependencyGraph(
      layout: layout,
      items: scope.quests.map {
        DependencyGraphItem(
          id: $0.id, title: $0.title, symbol: status($0).symbol, color: status($0).color)
      },
      selected: $selected, focusRequest: focusRequest,
      route: quest.map { layout.ancestors(of: $0.id, quests: scope.quests) } ?? [],
      fulfilled: fulfilled, search: $search, searchSubmission: searchSubmission,
      countText: L("%d quests", scope.members.count),
      legend: [
        .init(title: "Available", color: AppStyle.accent),
        .init(title: "Completed", color: AppStyle.mint), .init(title: "Locked", color: .secondary),
      ],
      onPick: { selected = $0 }
    ) { id, dimmed in
      if let item = index[id] {
        QuestTreeNode(
          quest: item, status: status(item), selected: selected == id,
          external: scope.externalIDs.contains(id), dimmed: dimmed,
          saved: practice[id]?.sessions ?? 0
        ) { selected = id }
      }
    }
  }
  private var inspector: some View {
    ScrollView {
      if let quest {
        let current = status(quest)
        let saved = practice[quest.id] ?? QuestPractice()
        VStack(alignment: .leading, spacing: 20) {
          HStack {
            Image(systemName: quest.kind == "Habit" ? "arrow.clockwise" : "checklist")
              .font(.system(size: 22, weight: .light)).foregroundStyle(current.color)
              .frame(width: 48, height: 48).background(
                current.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            Spacer()
            Label(LocalizedStringKey(current.title), systemImage: current.symbol)
              .font(.system(size: 11)).foregroundStyle(current.color)
          }
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(quest.title).font(.system(size: 20, weight: .semibold)).fixedSize(
              horizontal: false, vertical: true)
            Spacer(minLength: 8)
            PencilButton(label: "Edit quest") { store.sheet = .editQuest(quest.id) }
              .disabled(store.busy)
          }
          if !quest.outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(quest.outcome).font(.system(size: 12)).foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
          }
          Button {
            withAnimation(.easeInOut(duration: 0.18)) { stepsOpen.toggle() }
          } label: {
            HStack(spacing: 8) {
              Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(stepsOpen ? 90 : 0))
              Text("Steps").font(.system(size: 13, weight: .semibold))
              Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          if stepsOpen {
            QuestStepsEditor(quest: quest, showsHeading: false)
          }
          if scope.externalIDs.contains(quest.id) {
            Button {
              store.openQuestTree(quest.skill_id)
            } label: {
              Label(state.skill(quest.skill_id), systemImage: "arrow.up.right.square")
            }.buttonStyle(.borderless).help("Open source skill")
            HintButton(text: "Prerequisite from another skill")
          }
          HStack {
            metric("Saved sessions", value: "\(saved.sessions)")
            metric("Total time", value: L("%@ min", number(Double(saved.seconds) / 60)))
          }
          if quest.kind != "Habit" {
            Text(
              L("%d sessions planned · %d min each", quest.sessionTarget, quest.estimate_minutes)
            )
            .font(.system(size: 11)).foregroundStyle(.secondary)
          }
          if quest.kind == "Habit" {
            HintButton(text: "A habit counts toward this skill after 7 completed days.")
          }
          RowDivider()
          requirements(quest)
          if !unlocked.contains(quest.id), !summary.unlocked_skills.contains(quest.skill_id) {
            HintButton(text: "Complete the parent skill requirements first.")
          }
          if quest.status == "Cancelled" || quest.status == "Missed" {
            Button("Return to plan") {
              store.send("status", ["id": quest.id, "status": "Planned"])
            }
            .buttonStyle(.bordered).disabled(store.busy)
            HintButton(
              text: "Paused and unfinished quests still block verification. Cancelled and missed quests do not."
            )
          } else if state.active?.quest_id == quest.id {
            Button("Show focus session") { store.focusMode = true }.buttonStyle(.borderedProminent)
          } else if store.available(quest) {
            VStack(spacing: 10) {
              Button {
                store.startSession(quest.id)
              } label: {
                Label("Start session", systemImage: "play.fill").frame(maxWidth: .infinity)
              }.buttonStyle(.borderedProminent).controlSize(.large)
              if !store.strictLogging {
                Button("Log time…") { store.finish(quest) }.buttonStyle(.bordered).controlSize(.large)
              }
            }.disabled(!store.canStart || store.busy)
          }
          RowDivider()
          Button {
            store.newQuest(skillID: skill.id, prerequisiteID: quest.id)
          } label: {
            Label("Add next quest", systemImage: "plus.circle").frame(
              maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(.borderless).disabled(store.busy)
          let children = scope.members.filter { $0.dependencies.contains(quest.id) }
          if !children.isEmpty {
            Text("Unlocks").font(.system(size: 13, weight: .semibold))
            ForEach(children) { child in
              Button {
                reveal(child.id)
              } label: {
                HStack {
                  Image(systemName: status(child).symbol).foregroundStyle(status(child).color)
                  Text(child.title).font(.system(size: 12)).lineLimit(2)
                  Spacer(minLength: 0)
                  Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(
                    .secondary)
                }.contentShape(Rectangle())
              }.buttonStyle(.plain)
            }
          }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  private func metric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
      Text(LocalizedStringKey(title)).font(.system(size: 10)).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func requirements(_ quest: Quest) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Depends on").font(.system(size: 13, weight: .semibold))
      if quest.dependencies.isEmpty {
        Text("No quest prerequisites").font(.system(size: 12)).foregroundStyle(.secondary)
      }
      ForEach(Array(Set(quest.dependencies)).sorted(), id: \.self) { id in
        let parent = index[id]
        Button {
          if parent != nil { reveal(id) }
        } label: {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: fulfilled.contains(id) ? "checkmark.circle.fill" : "circle.dashed")
              .foregroundStyle(fulfilled.contains(id) ? AppStyle.mint : AppStyle.amber)
            Text(parent?.title ?? L("Missing prerequisite")).font(.system(size: 12)).lineLimit(3)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
          }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(parent == nil)
      }
    }
  }
}

private enum QuestTreeStatus {
  case done, available, locked, paused, cancelled, missed, active
  var title: String {
    switch self {
    case .done: "Completed"
    case .available: "Available"
    case .locked: "Locked"
    case .paused: "Paused"
    case .cancelled: "Cancelled"
    case .missed: "Missed"
    case .active: "In progress"
    }
  }
  var symbol: String {
    switch self {
    case .done: "checkmark.circle.fill"
    case .available: "circle.dotted"
    case .locked: "lock.fill"
    case .paused: "pause.circle"
    case .cancelled, .missed: "xmark.circle"
    case .active: "timer"
    }
  }
  var color: Color {
    switch self {
    case .done: AppStyle.mint
    case .available, .active: AppStyle.accent
    case .paused: AppStyle.amber
    case .locked, .cancelled, .missed: .secondary
    }
  }
}

private struct QuestTreeNode: View {
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  let quest: Quest
  let status: QuestTreeStatus
  let selected: Bool
  let external: Bool
  let dimmed: Bool
  let saved: Int
  let action: () -> Void
  @State private var hovered = false
  var body: some View {
    let _ = locale
    Button(action: action) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(
            systemName: external
              ? "arrow.up.right.square" : (quest.kind == "Habit" ? "arrow.clockwise" : "checklist")
          )
          .font(.system(size: 13)).foregroundStyle(status.color)
          .frame(width: 20, height: 24)
          Text(quest.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: status.symbol).font(.system(size: 10)).foregroundStyle(status.color)
        }
        Spacer(minLength: 0)
        HStack {
          Text(LocalizedStringKey(status.title)).font(.system(size: 10, weight: .medium))
            .foregroundStyle(status.color)
          Spacer()
          Text(
            quest.kind == "Habit" ? L("%d sessions", saved) : "\(saved) / \(quest.sessionTarget)"
          )
          .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
        GeometryReader { geometry in
          Capsule().fill(status.color.opacity(0.1))
          Capsule().fill(status.color.opacity(0.8))
            .frame(
              width: geometry.size.width
                * (status == .done
                  ? 1 : min(1, CGFloat(saved) / CGFloat(max(1, quest.sessionTarget)))))
        }.frame(height: 3)
      }.padding(14).frame(width: SkillTreeLayout.card.width, height: SkillTreeLayout.card.height)
        .background {
          RoundedRectangle(cornerRadius: 14).fill(
            AppChrome.island(scheme: scheme)
          )
          .overlay {
            RoundedRectangle(cornerRadius: 14).fill(status.color.opacity(selected ? 0.08 : 0))
          }
          .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(
              selected
                ? AppStyle.accent
                : (hovered ? status.color.opacity(0.5) : Color.primary.opacity(0.1)),
              lineWidth: selected ? 2 : 1)
          }
          .shadow(
            color: .black.opacity(scheme == .dark ? 0.12 : 0.04), radius: 4, y: 2)
        }.opacity(dimmed ? 0.3 : 1).contentShape(RoundedRectangle(cornerRadius: 14))
    }.buttonStyle(.plain).onHover { hovered = $0 }
      .accessibilityLabel("\(quest.title), \(L(status.title))")
      .accessibilityValue(L("%d saved, %d planned", saved, quest.sessionTarget))
      .accessibilityAddTraits(selected ? .isSelected : [])
  }
}
