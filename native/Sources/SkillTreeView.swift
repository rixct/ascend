import AppKit
import SwiftUI

struct SkillTreeView: View {
  @EnvironmentObject private var store: Store
  @Environment(\.locale) private var locale
  let state: GameState
  let summary: Summary
  @State private var layoutCache = SkillTreeLayoutCache()
  private let layoutKey: String
  private var layout: SkillTreeLayout { layoutCache.layout(skills: state.skills, key: layoutKey) }
  @State private var selected: String?
  @State private var route = Set<String>()
  private let unlocked: Set<String>
  private let skillIndex: [String: Skill]
  private let questsBySkill: [String: [Quest]]
  private let fulfilled: Set<String>
  @State private var focusRequest = UUID()
  init(state: GameState, summary: Summary) {
    self.state = state
    self.summary = summary
    layoutKey = SkillTreeLayout.signature(state.skills)
    unlocked = Set(summary.unlocked_skills)
    questsBySkill = Dictionary(grouping: state.quests, by: \.skill_id)
    fulfilled = state.fulfilledQuestIDs
    skillIndex = Dictionary(
      state.skills.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
  }
  private var skill: Skill? { state.skills.first { $0.id == selected } ?? state.skills.first }
  var body: some View {
    let _ = locale
    Group {
      if let id = store.questTreeSkill, let focused = state.skills.first(where: { $0.id == id }) {
        QuestTreeView(skill: focused, state: state, summary: summary).id(id)
      } else {
        overallTree
      }
    }
    .onAppear(perform: rebuild)
    .onChange(of: SkillTreeLayout.signature(state.skills)) { _ in
      rebuild()
      if let id = store.questTreeSkill, !state.skills.contains(where: { $0.id == id }) {
        store.questTreeSkill = nil
      }
    }
    .onChange(of: selected) { _ in updateRoute() }
    .onChange(of: store.questTreeSkill) { id in
      if let id { selected = id }
    }
  }
  private var overallTree: some View {
    PageFrame {
      VStack(spacing: 16) {
        if state.skills.isEmpty {
          Surface(fillHeight: true) {
            EmptyState(
              symbol: "point.3.connected.trianglepath.dotted", title: "Your skill tree starts here",
              message: "Add a skill, then connect new skills through prerequisites.",
              buttonTitle: "Add a skill"
            ) { store.sheet = .skill }
          }
        } else {
          HStack(alignment: .top, spacing: 16) {
            Surface(padding: 0, fillHeight: true) { graph }
              .clipShape(RoundedRectangle(cornerRadius: 16))
            Surface(padding: 0, fillHeight: true) { inspector }
              .frame(width: 280)
          }
        }
      }
      .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  private func rebuild() {
    if !state.skills.contains(where: { $0.id == selected }) { selected = state.skills.first?.id }
    updateRoute()
  }
  private func updateRoute() {
    route = selected.map { layout.ancestors(of: $0, skills: state.skills) } ?? []
  }
  private func status(_ skill: Skill) -> TreeStatus {
    if !unlocked.contains(skill.id) { return .locked }
    return skill.mastery > 0 ? .verified : .available
  }

  private var graph: some View {
    DependencyGraph(
      layout: layout,
      items: state.skills.map {
        DependencyGraphItem(
          id: $0.id, title: $0.displayTitle, symbol: status($0).symbol, color: status($0).color)
      },
      selected: $selected, focusRequest: focusRequest, route: route,
      fulfilled: Set(state.skills.filter { $0.mastery > 0 }.map(\.id)),
      searchTitle: "Find a skill", countText: L("%d skills", state.skills.count),
      legend: TreeStatus.allCases.map { DependencyGraphLegend(title: $0.title, color: $0.color) },
      onPick: { selected = $0 }
    ) { id, dimmed in
      if let item = skillIndex[id] {
        let quests = questsBySkill[id, default: []]
        TreeNode(
          skill: item, status: status(item), selected: selected == id,
          onRoute: route.contains(id), dimmed: dimmed, requirements: item.prerequisites.count,
          met: item.prerequisites.filter { (skillIndex[$0]?.mastery ?? 0) > 0 }.count,
          questCount: quests.isEmpty
            ? nil
            : L("%d / %d quests", quests.filter { fulfilled.contains($0.id) }.count, quests.count)
        ) {
          selected = id
        }
      }
    }
  }
  private func reveal(_ id: String) {
    selected = id
    focusRequest = UUID()
  }

  private var inspector: some View {
    ScrollView {
      if let skill {
        let current = status(skill)
        VStack(alignment: .leading, spacing: 22) {
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Image(systemName: treeDomain(skill.domain).symbol)
                .font(.system(size: 22, weight: .light)).foregroundStyle(current.color)
                .frame(width: 48, height: 48).background(
                  current.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
              Spacer()
              Label(LocalizedStringKey(current.title), systemImage: current.symbol).font(
                .system(size: 10, weight: .medium)
              )
              .foregroundStyle(current.color)
            }
            Text(skill.displayTitle).font(.system(size: 21, weight: .semibold)).fixedSize(
              horizontal: false, vertical: true)
            Text(LocalizedStringKey(treeDomain(skill.domain).title)).font(.system(size: 12))
              .foregroundStyle(
                .secondary)
            Text(FocusList.summary(skill))
            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(
              horizontal: false, vertical: true)
            PencilButton(label: "Edit skill") { store.sheet = .editSkill(skill.id) }
              .disabled(store.busy)
          }
          HStack(spacing: 0) {
            treeMetric("Experience", value: "\(number(Double(skill.xp_milli) / 1000)) XP")
            treeMetric("Verified milestones", value: "\(skill.mastery)")
          }
          RowDivider()
          requirements(skill)
          if layout.unresolved.contains(skill.id) {
            Label(
              "Some prerequisites could not be resolved.", systemImage: "exclamationmark.triangle"
            )
            .font(.system(size: 11)).foregroundStyle(AppStyle.amber)
          }
          Button {
            store.openQuestTree(skill.id)
          } label: {
            Label("Quest tree", systemImage: "point.3.filled.connected.trianglepath.dotted").frame(
              maxWidth: .infinity)
          }.buttonStyle(.bordered).controlSize(.large)
          let quests = questsBySkill[skill.id, default: []]
          if !quests.isEmpty {
            Text(
              L(
                "%d / %d quests completed", quests.filter { fulfilled.contains($0.id) }.count,
                quests.count)
            )
            .font(.system(size: 12)).foregroundStyle(.secondary)
          }
          if current != .locked {
            Button {
              store.sheet = .mastery(skill.id)
            } label: {
              Label("Verify mastery…", systemImage: "checkmark.seal")
                .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent).controlSize(.large)
              .disabled(!state.canVerifySkill(skill.id, summary: summary))
            if !state.skillQuestsCompleted(skill.id) {
              HintButton(text: "Complete all quests to verify this skill.")
            }
          }
          RowDivider()
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
              Text("Unlocks").font(.system(size: 13, weight: .semibold))
              HintButton(text: "New branches appear when you add dependent skills.")
            }
            let children = state.skills.filter { $0.prerequisites.contains(skill.id) }
            if !children.isEmpty {
              ForEach(children) { child in
                Button {
                  reveal(child.id)
                } label: {
                  HStack(spacing: 10) {
                    Image(systemName: status(child).symbol).foregroundStyle(status(child).color)
                    Text(child.displayTitle).font(.system(size: 12)).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(
                      .secondary)
                  }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
              }
            }
          }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }
  private func treeMetric(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(value).font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
      Text(L(title)).font(.system(size: 10)).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  @ViewBuilder private func requirements(_ skill: Skill) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 6) {
        Text("To unlock").font(.system(size: 13, weight: .semibold))
        if !skill.prerequisites.isEmpty {
          HintButton(
            text: "Verify one milestone in each prerequisite skill. XP alone does not unlock the next skill."
          )
        }
      }
      if skill.prerequisites.isEmpty {
        HStack(spacing: 6) {
          Label("No prerequisites", systemImage: "checkmark.circle.fill")
            .font(.system(size: 12)).foregroundStyle(AppStyle.mint)
          HintButton(text: "You can start practicing this skill.")
        }
      } else {
        let parents = skill.prerequisites
        let count = parents.filter { (skillIndex[$0]?.mastery ?? 0) > 0 }.count
        Text(L("%d of %d requirements met", count, parents.count)).font(.system(size: 11))
          .foregroundStyle(.secondary)
        ProgressTrack(value: Double(count) / Double(parents.count) * 100)
        ForEach(parents, id: \.self) { id in
          let parent = skillIndex[id]
          let met = (parent?.mastery ?? 0) > 0
          Button {
            if parent != nil { reveal(id) }
          } label: {
            HStack(alignment: .top, spacing: 10) {
              Image(systemName: met ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(met ? AppStyle.mint : AppStyle.amber).padding(.top, 2)
              VStack(alignment: .leading, spacing: 4) {
                Text(parent?.displayTitle ?? L("Missing prerequisite")).font(
                  .system(size: 12, weight: .medium))
                Text(LocalizedStringKey(met ? "Milestone verified" : "Verify 1 milestone"))
                  .font(.system(size: 11)).foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
              Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.secondary)
                .padding(.top, 4)
            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
          }.buttonStyle(.plain).disabled(parent == nil)
        }
      }
    }
  }
}

private enum TreeStatus: CaseIterable {
  case available, verified, locked
  var title: String {
    switch self {
    case .available: "Available"
    case .verified: "Verified"
    case .locked: "Locked"
    }
  }
  var symbol: String {
    switch self {
    case .available: "lock.open"
    case .verified: "checkmark.seal.fill"
    case .locked: "lock.fill"
    }
  }
  var color: Color {
    switch self {
    case .available: AppStyle.accent
    case .verified: AppStyle.mint
    case .locked: .secondary
    }
  }
}

private struct TreeNode: View {
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  let skill: Skill
  let status: TreeStatus
  let selected: Bool
  let onRoute: Bool
  let dimmed: Bool
  let requirements: Int
  let met: Int
  var questCount: String? = nil
  let action: () -> Void
  @State private var hovered = false
  var body: some View {
    let _ = locale
    Button(action: action) {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: treeDomain(skill.domain).symbol)
            .font(.system(size: 13)).foregroundStyle(status.color)
            .frame(width: 28, height: 28).background(
              status.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
          Text(skill.displayTitle).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
          Image(systemName: status.symbol).font(.system(size: 10)).foregroundStyle(status.color)
        }
        Spacer(minLength: 0)
        HStack {
          Text(LocalizedStringKey(status.title)).font(.system(size: 10, weight: .medium))
            .foregroundStyle(
              status.color)
          Spacer()
          Text(
            questCount
              ?? (requirements > 0 && status == .locked
                ? "\(met)/\(requirements)" : "\(number(Double(skill.xp_milli) / 1000)) XP")
          )
          .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
        }
        GeometryReader { geometry in
          Capsule().fill(status.color.opacity(0.1))
          Capsule().fill(status.color.opacity(status == .locked ? 0.5 : 0.85))
            .frame(
              width: geometry.size.width
                * (requirements == 0 ? 1 : CGFloat(met) / CGFloat(requirements)))
        }.frame(height: 3)
      }
      .padding(14).frame(width: SkillTreeLayout.card.width, height: SkillTreeLayout.card.height)
      .background {
        RoundedRectangle(cornerRadius: 14)
          .fill(scheme == .dark ? Color(white: 0.19) : Color.white)
          .overlay {
            RoundedRectangle(cornerRadius: 14).fill(status.color.opacity(selected ? 0.1 : 0.025))
          }
          .overlay {
            RoundedRectangle(cornerRadius: 14).strokeBorder(
              selected
                ? AppStyle.accent
                : (hovered || onRoute ? status.color.opacity(0.5) : Color.primary.opacity(0.1)),
              lineWidth: selected ? 2 : 1)
          }
          .shadow(
            color: selected ? AppStyle.accent.opacity(0.12) : Color.black.opacity(0.07),
            radius: selected ? 16 : 6, y: 3)
      }
      .opacity(dimmed ? 0.3 : 1).contentShape(RoundedRectangle(cornerRadius: 14))
    }
    .buttonStyle(.plain).onHover { hovered = $0 }
    .accessibilityLabel("\(skill.displayTitle), \(L(status.title))")
    .accessibilityValue("\(number(Double(skill.xp_milli) / 1000)) XP")
    .accessibilityAddTraits(selected ? [.isSelected] : [])
  }
}

private func treeDomain(_ domain: String) -> (title: String, symbol: String) {
  switch domain {
  case "Mind": ("Learning", "brain.head.profile")
  case "Body": ("Physical fitness", "figure.run")
  case "Organization": ("Organization", "square.stack.3d.up")
  case "Social": ("Social", "person.2")
  case "Recovery": ("Recovery", "leaf")
  default: (domain, "circle.hexagongrid")
  }
}
