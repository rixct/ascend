import AppKit
import Charts
import SwiftUI

struct Metric: View {
  @Environment(\.locale) private var locale
  let title: String
  let value: String
  var body: some View {
    let _ = locale
    VStack(alignment: .leading, spacing: 5) {
      Text(verbatim: value).font(.system(size: 33, weight: .medium))
        .monospacedDigit()
        .lineLimit(1).minimumScaleFactor(0.7)
      Text(L(title)).font(.system(size: 12)).foregroundStyle(.secondary)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(L(title)))
    .accessibilityValue(Text(verbatim: value))
  }
}

struct DashboardView: View {
  @Environment(\.locale) private var locale
  let state: GameState
  let summary: Summary
  var body: some View {
    let _ = locale
    GeometryReader { viewport in
      let sideBySide = viewport.size.width >= 760
      let layout = sideBySide
        ? AnyLayout(HStackLayout(alignment: .top, spacing: 42))
        : AnyLayout(VStackLayout(alignment: .leading, spacing: 30))
      ScreenLayout {
        HStack(alignment: .top, spacing: 38) {
          Metric(
            title: "Practice today",
            value: L(
              "%d min",
              state.sessions.filter { $0.day == summary.today }.reduce(0) { $0 + $1.seconds } / 60))
          Metric(
            title: "Discipline",
            value: summary.discipline.map {
              (summary.preliminary ? "≈" : "") + String(Int($0.rounded()))
            } ?? "—")
          Spacer(minLength: 8)
          Text(dateText(summary.today))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 9)
        }
        RowDivider()
        layout {
          CanvasSection(title: "Practice") {
            if state.active != nil {
              Surface(padding: 20) { TimerView(state: state, summary: summary) }
            } else {
              TimerView(state: state, summary: summary)
            }
          }
          DailyRoutineView(summary: summary)
            .frame(maxWidth: sideBySide ? 284 : .infinity, alignment: .leading)
        }
      }
    }
  }
}

struct TimerView: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  let state: GameState
  let summary: Summary
  @State private var notes = ""
  @State private var confirmReset = false
  @State private var confirmCancel = false
  var body: some View {
    let _ = locale
    VStack(alignment: .leading, spacing: 15) {
      if let active = state.active {
        if active.isStrict { StrictSessionStatus(active: active) }
        HStack {
          StatusPill(
            title: active.statusTitle,
            color: active.isCounting ? AppStyle.mint : AppStyle.amber,
            symbol: active.isCounting
              ? "circle.fill" : (active.focus_confirmed == false ? "hourglass" : "pause.fill"))
          if active.running && active.focus_confirmed == false {
            let skill = state.quest(active.quest_id).flatMap { quest in
              state.skills.first { $0.id == quest.skill_id }
            }
            HintButton(
              text: skill?.focusListMode == .exceptListed
                ? "Switch to an app or tab outside the list to resume counting. If the tab cannot be checked, allow browser access in macOS Automation settings."
                : "Open an allowed app or site to keep the timer going. This window always counts.")
          }
          Spacer()
          Text(state.quest(active.quest_id).map { state.skill($0.skill_id) } ?? "").font(
            .system(size: 12)
          ).foregroundStyle(Color.secondary).lineLimit(1)
        }
        Text(state.quest(active.quest_id)?.title ?? L("Session")).font(
          .system(size: 18, weight: .semibold)
        ).fixedSize(horizontal: false, vertical: true)
        Text(clock(active.elapsed_seconds))
          .font(.system(size: 49, weight: .light))
          .monospacedDigit()
          .contentTransition(.identity)
        if let quest = state.quest(active.quest_id) {
          ProgressTrack(
            value: Double(active.elapsed_seconds), total: Double(quest.estimate_minutes * 60))
        }
        TextField("Add a session note", text: $notes)
          .textFieldStyle(.plain)
          .font(.system(size: 13))
          .padding(.vertical, 8)
          .overlay(alignment: .bottom) { RowDivider() }
        .onSubmit { store.send("notes", ["id": active.id, "text": notes]) }
        .onAppear { notes = active.notes }
        .onChange(of: active.id) { _ in notes = active.notes }
        .onChange(of: notes) { value in
          store.send("notes", ["id": active.id, "text": value])
        }
        HStack(spacing: 10) {
          Button {
            store.send("pause")
          } label: {
            Label(
              L(active.running ? "Pause" : "Resume"), systemImage: active.running ? "pause" : "play"
            )
          }
          .buttonStyle(.bordered)
          Menu {
            Button {
              confirmReset = true
            } label: {
              Label("Reset timer", systemImage: "arrow.counterclockwise")
            }
            Button(role: .destructive) {
              confirmCancel = true
            } label: {
              Label("Cancel session", systemImage: "xmark")
            }
          } label: {
            Image(systemName: "ellipsis").frame(width: 25, height: 24)
          }
          .menuStyle(.borderlessButton)
          .menuIndicator(.hidden)
          .fixedSize()
          .accessibilityLabel("Session actions")
          .help("Session actions")
          Spacer(minLength: 4)
          Button("Finish session") { store.finish() }.buttonStyle(.borderedProminent)
        }
        .confirmationDialog(
          "Cancel this session?", isPresented: $confirmCancel, titleVisibility: .visible
        ) {
          Button("Cancel session", role: .destructive) {
            store.send("discard_session", ["id": active.id])
          }
          Button("Keep session", role: .cancel) {}
        } message: {
          Text("This session's time and notes will not be saved.")
        }
        .confirmationDialog("Reset the timer?", isPresented: $confirmReset, titleVisibility: .visible) {
          Button("Reset timer", role: .destructive) { store.send("reset_timer") }
          Button("Cancel", role: .cancel) {}
        } message: {
          Text("Counted time for this session returns to zero.")
        }
      } else {
        let practices = todayPractices
        if practices.isEmpty {
          EmptyState(
            symbol: "viewfinder", title: "Nothing to practice yet",
            buttonTitle: "Create a quest", compact: true
          ) { store.sheet = .quest }
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(practices) { quest in
              if quest.id != practices.first?.id { RowDivider() }
              practiceRow(quest)
            }
          }
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private var todayPractices: [Quest] {
    let unlocked = Set(summary.unlocked_quests)
    return state.quests.filter { quest in
      !quest.closed && quest.status != "Paused" && unlocked.contains(quest.id)
    }.sorted { a, b in
      let aRank = practiceRank(a)
      let bRank = practiceRank(b)
      if aRank != bRank { return aRank < bRank }
      let aDone = doneToday(a)
      let bDone = doneToday(b)
      if aDone != bDone { return !aDone }
      if a.priority != b.priority { return a.priority > b.priority }
      return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
    }
  }
  private func practiceRank(_ quest: Quest) -> Int {
    switch quest.kind {
    case "Habit": 0
    case "Daily": 1
    default: 2
    }
  }
  private func doneToday(_ quest: Quest) -> Bool {
    quest.kind == "Habit"
      && state.sessions.contains { $0.quest_id == quest.id && $0.day == summary.today }
  }
  private func practiceRow(_ quest: Quest) -> some View {
    let done = doneToday(quest)
    let saved = state.sessions.filter { $0.quest_id == quest.id }.count
    let details = [
      state.skill(quest.skill_id),
      L("%d min", quest.estimate_minutes),
      quest.kind != "Habit" && quest.sessionTarget > 1 ? L("%d of %d", saved, quest.sessionTarget) : "",
    ].filter { !$0.isEmpty }.joined(separator: " · ")
    return HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(quest.title)
          .font(.system(size: 14, weight: .medium))
          .foregroundStyle(done ? Color.secondary : Color.primary)
          .fixedSize(horizontal: false, vertical: true)
        Text(verbatim: details)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 8)
      if done {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 16))
          .foregroundStyle(AppStyle.mint)
          .accessibilityLabel("Done today")
      } else if store.available(quest) {
        Button {
          store.startSession(quest.id)
        } label: {
          Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 28, height: 22)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!store.canStart || store.busy)
        .accessibilityLabel("Start")
        .help("Start")
      }
    }
    .padding(.vertical, 9)
  }
}

private struct CanvasSelection: ViewModifier {
  let selected: Bool
  @State private var hovered = false

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 9)
      .padding(.vertical, 9)
      .background {
        RoundedRectangle(cornerRadius: 8)
          .fill(selected ? AppStyle.accent.opacity(0.14) : Color.primary.opacity(hovered ? 0.05 : 0))
      }
      .onHover { hovered = $0 }
  }
}

struct FocusView: View {
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  @AppStorage("style") private var style = "minimal"
  @EnvironmentObject var store: Store
  let state: GameState
  let summary: Summary
  var body: some View {
    let _ = locale
    VStack(alignment: .leading, spacing: 22) {
      HStack {
        Label("Focus", systemImage: "viewfinder").font(.system(size: 15, weight: .semibold))
        Spacer()
        Button("Back to today") { store.focusMode = false }.buttonStyle(.borderless)
      }
      if state.active != nil {
        Surface(padding: 24) { TimerView(state: state, summary: summary) }
      } else {
        TimerView(state: state, summary: summary)
      }
    }.frame(maxWidth: 530).padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(
      AppChrome.canvas(style: style, scheme: scheme))
  }
}

struct CharacterView: View {
  @Environment(\.locale) private var locale
  @AppStorage("characterSplit") private var split = 0.42
  @State private var resizeCursor = false
  let state: GameState
  let summary: Summary
  private var discipline: Attribute? { summary.attributes.first { $0.name == "Дисциплина" } }
  var body: some View {
    let _ = locale
    PageFrame {
      GeometryReader { geo in
        let total = geo.size.width
        let gap: CGFloat = 9
        if total >= ProfileColumn.minPane + gap + ProfileColumn.minChart {
          let left = leftWidth(total: total, gap: gap)
          HStack(spacing: 0) {
            profile.frame(width: left)
            divider(total: total, gap: gap)
            attributes.frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .coordinateSpace(name: "character-split")
          .frame(width: total, height: geo.size.height, alignment: .leading)
        } else {
          ScrollView {
            VStack(spacing: 0) {
              profile
              RowDivider().padding(.horizontal, ProfileColumn.padding)
              attributes.frame(height: 360)
            }
          }
        }
      }
      .frame(minHeight: 480)
    }
  }
  private var profile: some View {
    VStack(alignment: .leading, spacing: 22) {
      HStack(spacing: 16) {
        ProfileAvatar(encodedImage: state.settings.avatar, size: 68, circular: true)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 4) {
          Text(state.settings.name)
            .font(.system(size: 26, weight: .semibold))
            .lineLimit(2)
          Text(L("Level %d", summary.level))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
        }
      }
      if let bio = state.settings.bio, !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        Text(bio).font(.system(size: 14)).foregroundStyle(.secondary)
          .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 12) {
          Text(L("%@ total XP", number(Double(state.character_xp_milli) / 1000)))
            .lineLimit(1)
          Spacer(minLength: 8)
          Text("\(number(summary.level_xp)) / \(number(summary.next_xp)) XP")
            .lineLimit(1)
            .monospacedDigit()
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.secondary)
        ProgressTrack(value: summary.level_xp, total: summary.next_xp, height: 5)
      }
    }
    .frame(maxWidth: 350, alignment: .leading)
    .padding(ProfileColumn.padding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private var attributes: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        Text("Attributes").font(.system(size: 15, weight: .semibold))
        Spacer(minLength: 12)
        if let discipline {
          Text(verbatim: "\(englishName(discipline.name)) \(Int(discipline.value.rounded()))")
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(.secondary)
        }
      }
      AttributeHexagon(attributes: summary.attributes)
        .frame(maxWidth: 570, maxHeight: 495)
        .frame(maxWidth: .infinity)
    }
    .padding(26)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private func divider(total: CGFloat, gap: CGFloat) -> some View {
    Color.clear
      .frame(width: gap)
      .frame(maxHeight: .infinity)
      .overlay { Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1) }
      .contentShape(Rectangle())
      .onHover { inside in
        guard inside != resizeCursor else { return }
        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        resizeCursor = inside
      }
      .onDisappear {
        if resizeCursor {
          NSCursor.pop()
          resizeCursor = false
        }
      }
      .highPriorityGesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .named("character-split"))
          .onChanged { value in
            let available = max(1, total - gap)
            guard available > ProfileColumn.minPane + ProfileColumn.minChart else { return }
            let next = min(
              max(value.location.x - gap / 2, ProfileColumn.minPane),
              available - ProfileColumn.minChart)
            split = Double(next / available)
          }
      )
      .accessibilityLabel("Adjust divider")
      .accessibilityAdjustableAction { direction in
        let available = max(1, total - gap)
        guard available > ProfileColumn.minPane + ProfileColumn.minChart else { return }
        let delta: CGFloat = direction == .increment ? 24 : -24
        let next = min(
          max(leftWidth(total: total, gap: gap) + delta, ProfileColumn.minPane),
          available - ProfileColumn.minChart)
        split = Double(next / available)
      }
      .help("Adjust divider")
  }
  private func leftWidth(total: CGFloat, gap: CGFloat) -> CGFloat {
    let available = max(0, total - gap)
    guard available > ProfileColumn.minPane + ProfileColumn.minChart else {
      return min(ProfileColumn.minPane, available)
    }
    return min(
      max(available * CGFloat(split), ProfileColumn.minPane),
      available - ProfileColumn.minChart)
  }
}

private enum ProfileColumn {
  static let padding: CGFloat = 32
  static let minPane: CGFloat = 330
  static let minChart: CGFloat = 370
}

private struct AttributeHexagon: View {
  @Environment(\.locale) private var locale
  let attributes: [Attribute]
  private let names = [
    "Интеллект", "Концентрация", "Социальные навыки",
    "Восстановление", "Физическая форма", "Самоорганизация",
  ]
  private var spokes: [(name: String, value: Double)] {
    names.map { name in
      let value = attributes.first { $0.name == name }?.value ?? 0
      return (name, value.isFinite ? min(max(value, 0), 100) : 0)
    }
  }
  var body: some View {
    let _ = locale
    GeometryReader { geo in
      let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
      let labelWidth = min(112, geo.size.width / 3)
      let radius = max(12, min((geo.size.width - labelWidth) * 0.53, geo.size.height * 0.37) - 24)
      ZStack {
        Canvas { context, _ in
          for step in 1...4 {
            context.stroke(
              polygon(center: center, radius: radius * CGFloat(step) / 4, scale: 1),
              with: .color(.primary.opacity(step == 4 ? 0.22 : 0.10)),
              lineWidth: 1)
          }
          for index in 0..<6 {
            var axis = Path()
            axis.move(to: center)
            axis.addLine(to: vertex(center: center, radius: radius, index: index, scale: 1))
            context.stroke(axis, with: .color(.primary.opacity(0.12)), lineWidth: 1)
          }
          let shape = polygon(center: center, radius: radius, scale: nil)
          context.fill(shape, with: .color(AppStyle.accent.opacity(0.28)))
          context.stroke(shape, with: .color(AppStyle.accent), lineWidth: 2)
          for index in 0..<6 where spokes[index].value > 0 {
            let point = vertex(
              center: center, radius: radius, index: index, scale: spokes[index].value / 100)
            let dot = Path(
              ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            context.fill(dot, with: .color(AppStyle.accent))
          }
        }
        ForEach(0..<6, id: \.self) { index in
          let point = vertex(center: center, radius: radius + 38, index: index, scale: 1)
          let labelOffset: CGFloat = switch index {
          case 1, 5: -10
          case 2, 4: 10
          default: 0
          }
          VStack(spacing: 2) {
            Text(englishName(spokes[index].name))
              .font(.system(size: 11, weight: .medium))
              .multilineTextAlignment(.center)
              .lineLimit(2)
            Text("\(Int(spokes[index].value.rounded()))")
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .foregroundStyle(.secondary)
          }
          .frame(width: labelWidth)
          .position(
            x: min(max(point.x, labelWidth / 2), geo.size.width - labelWidth / 2),
            y: point.y + labelOffset)
        }
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Attributes")
    .accessibilityValue(
      Text(
        verbatim: spokes.map { "\(englishName($0.name)) \(Int($0.value.rounded()))" }.joined(
          separator: ", ")))
  }
  private func polygon(center: CGPoint, radius: CGFloat, scale: Double?) -> Path {
    var path = Path()
    for index in 0..<6 {
      let amount = scale ?? spokes[index].value / 100
      let point = vertex(center: center, radius: radius, index: index, scale: amount)
      if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
  }
  private func vertex(center: CGPoint, radius: CGFloat, index: Int, scale: Double) -> CGPoint {
    let angle = -Double.pi / 2 + Double(index) * Double.pi / 3
    let reach = radius * CGFloat(scale)
    return CGPoint(
      x: center.x + CGFloat(cos(angle)) * reach,
      y: center.y + CGFloat(sin(angle)) * reach)
  }
}

struct MilestonesSheet: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject private var store: Store
  let state: GameState
  var body: some View {
    let _ = locale
    VStack(alignment: .leading, spacing: 18) {
      Text("Milestones").font(.system(size: 21, weight: .semibold))
      LazyVGrid(
        columns: [
          GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading),
        ], spacing: 18
      ) {
        achievement("First step", detail: "Complete a session", earned: !state.sessions.isEmpty)
        achievement(
          "Finding your rhythm", detail: "Complete 10 sessions",
          earned: state.sessions.count >= 10)
        achievement(
          "Proof of progress", detail: "Verify a skill milestone",
          earned: state.skills.contains { $0.mastery > 0 })
        achievement(
          "A thousand earned", detail: "Reach 1,000 XP",
          earned: state.character_xp_milli >= 1_000_000)
      }
      HStack {
        Spacer()
        Button("Done") { store.sheet = nil }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          .keyboardShortcut(.defaultAction)
          .keyboardShortcut(.cancelAction)
      }
    }
    .padding(26)
    .frame(width: 520)
  }
  private func achievement(_ name: String, detail: String, earned: Bool) -> some View {
    HStack(spacing: 12) {
      Image(systemName: earned ? "checkmark.seal.fill" : "seal").font(
        .system(size: 21, weight: .light)
      ).foregroundStyle(earned ? AppStyle.mint : Color.secondary.opacity(0.45)).frame(
        width: 42, height: 42
      ).background(
        (earned ? AppStyle.mint : Color.secondary).opacity(0.07),
        in: RoundedRectangle(cornerRadius: 12))
      VStack(alignment: .leading, spacing: 4) {
        Text(L(name)).font(.system(size: 13, weight: .medium))
        Text(L(detail)).font(.system(size: 11)).foregroundStyle(Color.secondary).fixedSize(
          horizontal: false, vertical: true)
      }
    }.padding(.vertical, 5)
  }
}

struct SkillsView: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  let state: GameState
  let summary: Summary
  @State private var selected: String?
  @State private var expanded: Set<String> = []
  var body: some View {
    let _ = locale
    PageFrame {
      Group {
        if state.skills.isEmpty {
          EmptyState(
            symbol: "point.3.connected.trianglepath.dotted",
            title: "No skills yet",
            message: "Add a skill to track practice and milestones.",
            buttonTitle: "Add a skill"
          ) { store.sheet = .skill }
        } else {
          skillsSplit
        }
      }
      .padding(.horizontal, 32)
      .padding(.top, 20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .onAppear { selected = state.skills.first?.id }
    .onChange(of: state.skills.map(\.id)) { ids in
      if selected == nil || !ids.contains(selected ?? "") { selected = ids.first }
    }
    .confirmationDialog(
      store.skillSelection.count > 1 ? L("Delete these skills?") : L("Delete this skill?"),
      isPresented: $store.confirmSkillDelete,
      titleVisibility: .visible
    ) {
      Button(L("Delete"), role: .destructive) { store.deleteSelectedSkills() }
    } message: {
      Text(
        store.skillSelection.count > 1
          ? L("The selected skills and their quests, sessions, and weekly goals will be removed.")
          : L("The skill and its quests, sessions, and weekly goals will be removed."))
    }
  }
  private var skillsSplit: some View {
    HStack(spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(state.skills) { skill in skillRow(skill) }
        }
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(width: 222)
      Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
      if let skill = state.skills.first(where: { $0.id == selected }) ?? state.skills.first {
        ScrollView {
          VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 18) {
              HStack {
                Text(skill.displayTitle).font(.system(size: 25, weight: .semibold))
                Spacer()
                PencilButton(label: "Edit skill") { store.sheet = .editSkill(skill.id) }
                  .disabled(store.busy)
                if !summary.unlocked_skills.contains(skill.id) {
                  StatusPill(title: "Locked", color: .secondary, symbol: "lock.fill")
                }
              }
              HStack(spacing: 28) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(number(Double(skill.xp_milli) / 1000)) XP")
                      .font(.system(size: 21, weight: .medium)).monospacedDigit()
                    Text("Experience").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(skill.mastery)").font(.system(size: 21, weight: .medium))
                      .monospacedDigit()
                    Text("Verified milestones").font(.system(size: 12)).foregroundStyle(.secondary)
                }
              }
              if !skill.prerequisites.isEmpty {
                Label(
                  skill.prerequisites.map { state.skill($0) }.joined(separator: ", "),
                  systemImage: "arrow.turn.down.right"
                ).font(.system(size: 12)).foregroundStyle(Color.secondary)
              }
              Text(FocusList.summary(skill))
                .font(.system(size: 12)).foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
              HStack(spacing: 8) {
                  Button("Verify mastery…") { store.sheet = .mastery(skill.id) }
                    .buttonStyle(.bordered)
                    .disabled(!state.canVerifySkill(skill.id, summary: summary))
                if !state.skillQuestsCompleted(skill.id) {
                  HintButton(text: "Complete all quests to verify this skill.")
                }
              }
            }
            RowDivider()
            CanvasSection(title: "Verified outcomes") {
              if skill.evidence.isEmpty {
                EmptyState(
                  symbol: "checkmark.seal", title: "No verified outcomes yet",
                  compact: true)
              } else {
                ForEach(Array(skill.evidence.enumerated()), id: \.offset) { _, text in
                  Label {
                    Text(text).font(.system(size: 13)).textSelection(.enabled)
                  } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(AppStyle.mint)
                  }
                }
              }
            }
            RowDivider()
            CanvasSection(title: "Recent practice") {
              let sessions = Array(
                state.sessions.filter { $0.skill_id == skill.id }.suffix(8).reversed())
              if sessions.isEmpty {
                EmptyState(
                  symbol: "clock", title: "No sessions yet", compact: true)
              } else {
                VStack(spacing: 14) {
                  ForEach(sessions) { session in
                    HStack {
                      Text(dateText(session.day)).font(.system(size: 13))
                      Spacer()
                      Text(L("%@ min", number(Double(session.seconds) / 60))).font(
                        .system(size: 12)
                      )
                      .foregroundStyle(Color.secondary)
                      Text("+\(number(Double(session.reward_milli) / 1000)) XP").font(
                        .system(size: 12, weight: .medium)
                      ).foregroundStyle(AppStyle.accent).frame(width: 70, alignment: .trailing)
                    }
                  }
                }
              }
            }
          }
          .frame(maxWidth: 720, alignment: .leading)
          .padding(.leading, 28)
          .padding(.bottom, 24)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
  private func skillRow(_ skill: Skill) -> some View {
    let open = selected == skill.id
    let shown = expanded.contains(skill.id)
    let quests = state.quests.filter { $0.skill_id == skill.id }
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Button {
          if expanded.contains(skill.id) {
            expanded.remove(skill.id)
          } else {
            expanded.insert(skill.id)
          }
        } label: {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(shown ? 90 : 0))
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Quests")
        .opacity(quests.isEmpty ? 0 : 1)
        .disabled(quests.isEmpty)
        .accessibilityHidden(quests.isEmpty)
        Button {
          if store.skillEditing {
            if store.skillSelection.contains(skill.id) {
              store.skillSelection.remove(skill.id)
            } else {
              store.skillSelection.insert(skill.id)
            }
          } else {
            selected = skill.id
          }
        } label: {
          HStack(spacing: 8) {
            if store.skillEditing {
              Image(
                systemName: store.skillSelection.contains(skill.id)
                  ? "checkmark.circle.fill" : "circle"
              )
              .foregroundStyle(AppStyle.accent)
            }
            Image(
              systemName: summary.unlocked_skills.contains(skill.id) ? "circle.hexagongrid" : "lock"
            )
            .font(.system(size: 14, weight: .light))
            .frame(width: 18)
            .foregroundStyle(open ? AppStyle.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(skill.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
              Text("\(number(Double(skill.xp_milli) / 1000)) XP")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if skill.mastery > 0 {
              Image(systemName: "checkmark.seal.fill").font(.system(size: 12))
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(open ? .isSelected : [])
      }
      .modifier(CanvasSelection(selected: open))
      if shown {
        if quests.isEmpty {
          Text("No quests yet")
            .font(.system(size: 12))
            .foregroundStyle(Color.secondary)
            .padding(.leading, 36)
            .padding(.vertical, 4)
        } else {
          ForEach(quests) { quest in
            HStack(spacing: 8) {
              Image(systemName: questMark(quest).symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(questMark(quest).color)
                .frame(width: 14)
              Text(quest.title).font(.system(size: 12)).lineLimit(2)
            }
            .padding(.leading, 32)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
    }
  }
  private func questMark(_ quest: Quest) -> (symbol: String, color: Color) {
    if quest.status == "Completed" { return ("checkmark", AppStyle.mint) }
    let overdue =
      quest.status == "Missed"
      || (quest.deadline.map { $0 < summary.today } ?? false && quest.status != "Cancelled")
    if overdue { return ("xmark", Color(red: 0.86, green: 0.35, blue: 0.32)) }
    return ("circle", Color.secondary)
  }
}

struct QuestsView: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  let state: GameState
  let summary: Summary
  @Binding var search: String
  @Binding var filter: Int
  @State private var selected: String?
  @State private var expanded = Set<String>()
  private var quests: [Quest] {
    state.quests.reversed().filter {
      (filter == 2 || (filter == 0 ? !$0.closed : $0.closed))
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
    }
  }
  var body: some View {
    let _ = locale
    let visibleQuests = quests
    PageFrame {
      Group {
        if state.quests.isEmpty {
          EmptyState(
            symbol: "checklist", title: "No quests yet",
            message: "Create a quest to plan what to practice.",
            buttonTitle: "Create a quest"
          ) { store.sheet = .quest }
        } else {
          questSplit(visibleQuests)
        }
      }
      .padding(.horizontal, 32)
      .padding(.top, 20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .onAppear { if selected == nil { selected = visibleQuests.first?.id } }
    .onChange(of: visibleQuests.map(\.id)) { ids in
      if selected == nil || !ids.contains(selected ?? "") { selected = ids.first }
    }
  }
  private func questSplit(_ quests: [Quest]) -> some View {
    let practice = QuestPractice.totals(state.sessions)
    return HStack(spacing: 0) {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 4) {
          ForEach(quests) { quest in questRow(quest) }
        }
        .padding(.vertical, 8)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(width: 222)
      .frame(maxHeight: .infinity, alignment: .top)
      Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1).accessibilityHidden(true)
      Group {
        if let quest = quests.first(where: { $0.id == selected }) ?? quests.first {
          questDetail(quest, practice: practice)
        } else {
          EmptyState(
            symbol: search.isEmpty ? "checklist" : "magnifyingglass",
            title: search.isEmpty
              ? (filter == 1 ? "Nothing closed out yet" : "No active quests")
              : "No matching quests",
            buttonTitle: search.isEmpty ? (filter == 1 ? nil : "Create a quest") : "Clear search"
          ) {
            if search.isEmpty {
              store.sheet = .quest
            } else {
              search = ""
              filter = 2
            }
          }
          .padding(.leading, 28)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
  private func questDetail(_ quest: Quest, practice: [String: QuestPractice]) -> some View {
    let saved = practice[quest.id] ?? QuestPractice()
    return ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          StatusPill(
            title: summary.unlocked_quests.contains(quest.id) ? quest.statusName : "Locked",
            color: quest.status == "Completed"
              ? AppStyle.mint : quest.status == "Active" ? AppStyle.accent : .secondary)
          HStack(alignment: .firstTextBaseline) {
            Text(quest.title).font(.system(size: 25, weight: .semibold)).fixedSize(
              horizontal: false, vertical: true)
            Spacer(minLength: 8)
            PencilButton(label: "Edit quest") { store.sheet = .editQuest(quest.id) }
              .disabled(store.busy)
          }
        }
        if !quest.outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          Text(quest.outcome).font(.system(size: 14)).foregroundStyle(Color.secondary)
            .lineSpacing(4).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        RowDivider()
        LazyVGrid(
          columns: [
            GridItem(.flexible(), alignment: .leading),
            GridItem(.flexible(), alignment: .leading),
          ], alignment: .leading, spacing: 16
        ) {
          detailMetric("Skill", state.skill(quest.skill_id))
          detailMetric("How it repeats", quest.kindName)
          detailMetric("Time", L("%d min", quest.estimate_minutes))
          if quest.kind == "Habit" {
            detailMetric("Days to establish", "\(quest.sessionTarget)")
          } else {
            detailMetric("Sessions", "\(saved.sessions) / \(quest.sessionTarget)")
          }
        }
        if quest.kind != "Habit" {
          Text(L("%@ min total", number(Double(saved.seconds) / 60)))
            .font(.system(size: 12)).foregroundStyle(.secondary)
          ProgressTrack(
            value: min(100, Double(saved.sessions) / Double(max(1, quest.sessionTarget)) * 100))
        }
        if let deadline = quest.deadline {
          Label(dateText(deadline), systemImage: "calendar").font(.system(size: 12))
            .foregroundStyle(.secondary)
        }
        HStack(spacing: 10) {
          if store.available(quest) {
            Button {
              store.startSession(quest.id)
            } label: {
              Label("Start session", systemImage: "play.fill")
            }.buttonStyle(.borderedProminent).disabled(!store.canStart)
            if !store.strictLogging {
              Button("Log time…") { store.finish(quest) }.buttonStyle(.borderless)
                .disabled(!store.canStart)
            }
          }
          if !quest.closed {
            Menu {
              Button(L(quest.status == "Paused" ? "Return to plan" : "Pause quest")) {
                store.send(
                  "status",
                  ["id": quest.id, "status": quest.status == "Paused" ? "Planned" : "Paused"])
              }
              Button("Cancel quest", role: .destructive) {
                store.send("status", ["id": quest.id, "status": "Cancelled"])
              }
            } label: {
              Image(systemName: "ellipsis").frame(width: 25, height: 24)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Quest actions")
            .help("Quest actions")
          }
        }
      }
      .frame(maxWidth: 720, alignment: .leading)
      .padding(.leading, 28)
      .padding(.bottom, 24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func detailMetric(_ title: LocalizedStringKey, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
      Text(value).font(.system(size: 14, weight: .medium)).lineLimit(2)
    }
  }
  private func questRow(_ quest: Quest) -> some View {
    let shown = expanded.contains(quest.id)
    let chosen = selected == quest.id
    let mark = questMark(quest)
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        Button {
          withAnimation(.easeInOut(duration: 0.18)) {
            if shown { expanded.remove(quest.id) } else { expanded.insert(quest.id) }
          }
        } label: {
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .rotationEffect(.degrees(shown ? 90 : 0))
            .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text("Steps"))
        Button {
          selected = quest.id
        } label: {
          HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
              Text(quest.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
              Text(state.skill(quest.skill_id)).font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let mark {
              Image(systemName: mark.symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(mark.color)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
      }
      .modifier(CanvasSelection(selected: chosen))
      if shown {
        QuestStepsEditor(quest: quest, showsHeading: false)
          .padding(.leading, 32)
          .padding(.trailing, 8)
          .padding(.vertical, 4)
      }
    }
  }
  private func questMark(_ quest: Quest) -> (symbol: String, color: Color)? {
    if quest.status == "Completed" { return ("checkmark", AppStyle.mint) }
    let overdue =
      quest.status == "Missed"
      || (quest.deadline.map { $0 < summary.today } ?? false && quest.status != "Cancelled")
    if overdue { return ("xmark", Color(red: 0.86, green: 0.35, blue: 0.32)) }
    if quest.status == "Paused" { return ("pause", Color.secondary) }
    if quest.status == "Active" { return ("play.fill", AppStyle.accent) }
    return nil
  }
}

struct BalanceView: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  let state: GameState
  let summary: Summary
  @State private var explanation = false
  private var targets: [WeeklyTarget] { state.targets.filter { $0.week == summary.week } }
  var body: some View {
    let _ = locale
    ScreenLayout(maxWidth: 820) {
      HStack(spacing: 20) {
        Metric(title: "Suggested workload", value: L("%d min", summary.suggested_minutes))
        Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1, height: 30)
          .accessibilityHidden(true)
        Text(englishText(summary.recommendation))
          .font(.system(size: 15, weight: .medium))
          .fixedSize(horizontal: false, vertical: true)
        Spacer()
        Button {
          explanation.toggle()
        } label: {
          Image(systemName: "info.circle").foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About your rhythm")
        .help("About your rhythm")
        .popover(isPresented: $explanation) {
          Text(englishText(summary.recommendation_detail)).font(.system(size: 13)).lineSpacing(4)
            .frame(width: 310, alignment: .leading).padding(18)
        }
      }
      RowDivider()
      CanvasSection(
        title: "This week", detail: summary.balance.map { L("%d%% complete", Int($0.rounded())) }
      ) {
        if targets.isEmpty {
          EmptyState(symbol: "scope", title: "No weekly goals yet", compact: true)
        } else {
          VStack(spacing: 22) { ForEach(targets) { target in targetRow(target) } }
        }
      }
      RowDivider()
      CanvasSection(
        title: "Today's check-in",
        actionTitle: state.checkins.contains(where: { $0.day == summary.today }) ? "Update…" : nil,
        pencil: true,
        action: { store.sheet = .checkin }
      ) {
        if let check = state.checkins.first(where: { $0.day == summary.today }) {
          HStack(spacing: 24) {
            condition("Energy", value: check.energy, color: AppStyle.mint)
            condition("Fatigue", value: check.fatigue, color: AppStyle.amber)
            condition("Focus", value: check.focus, color: AppStyle.blue)
          }
        } else {
          EmptyState(
            symbol: "sun.horizon", title: "A quick check-in helps shape a realistic plan for today.",
            buttonTitle: "Check in", compact: true
          ) { store.sheet = .checkin }
        }
      }
      if state.targets.contains(where: { $0.week > summary.week }) {
        RowDivider()
        CanvasSection(title: "Next week") {
          VStack(spacing: 22) {
            ForEach(state.targets.filter { $0.week > summary.week }) { target in targetRow(target) }
          }
        }
      }
    }
  }
  private func condition(_ title: String, value: Int, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(L(title)).font(.system(size: 13))
        Spacer()
        Text("\(value)").font(.system(size: 13, weight: .medium, design: .rounded)).foregroundStyle(
          .secondary)
      }
      ProgressTrack(value: Double(value), color: color)
    }.frame(maxWidth: .infinity)
  }
  private func targetRow(_ target: WeeklyTarget) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(state.skill(target.skill_id)).font(.system(size: 14, weight: .medium))
        Spacer()
        Text("\(number(summary.actual(target.id))) / \(number(target.target)) \(target.unitName)")
          .font(.system(size: 12)).foregroundStyle(Color.secondary)
      }
      ProgressTrack(value: summary.actual(target.id), total: target.target)
    }
  }
}

struct PracticeChart: View {
  @Environment(\.locale) private var locale
  let days: [HistoryDay]
  var body: some View {
    let _ = locale
    Chart(days) { day in
      BarMark(
        x: .value("Day", chartDate(day.day), unit: .day), y: .value("Minutes", day.minutes),
        width: days.count <= 7 ? .fixed(18) : .ratio(0.56)
      )
      .foregroundStyle(AppStyle.accent.opacity(0.9)).cornerRadius(3)
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: min(days.count, 7))) { _ in
        AxisValueLabel(
          format: days.count <= 7
            ? .dateTime.weekday(.abbreviated) : .dateTime.month(.abbreviated).day()
        ).font(.system(size: 10)).foregroundStyle(Color.secondary)
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(
          Color.primary.opacity(0.07))
        AxisValueLabel().font(.system(size: 10)).foregroundStyle(Color.secondary)
      }
    }
    .chartPlotStyle { plot in plot.padding(.top, 6) }
  }
}

struct AnalyticsView: View {
  @Environment(\.locale) private var locale
  let state: GameState
  let summary: Summary
  @State private var range = 28
  @State private var page = 0
  private var days: [HistoryDay] {
    let count = summary.history.count
    guard count > 0 else { return [] }
    let current = min(page, max(0, (count - 1) / range))
    let end = count - current * range
    let start = max(0, end - range)
    return Array(summary.history[start..<end])
  }
  private var canGoOlder: Bool {
    let count = summary.history.count
    let current = min(page, max(0, (count - 1) / range))
    return count - current * range - range > 0
  }
  private var periodTitle: String {
    guard let first = days.first?.day, let last = days.last?.day else { return "" }
    if first == last { return dateText(first) }
    return "\(dateText(first)) – \(dateText(last))"
  }
  private var minutes: Double { days.reduce(0) { $0 + $1.minutes } }
  private var minutesBySkill: [String: Double] {
    guard let first = days.first?.day, let last = days.last?.day else { return [:] }
    var totals: [String: Double] = [:]
    for session in state.sessions where session.day >= first && session.day <= last {
      totals[session.skill_id, default: 0] += Double(session.seconds) / 60
    }
    return totals
  }
  var body: some View {
    let _ = locale
    ScreenLayout(maxWidth: 920) {
      HStack(spacing: 10) {
        Button {
          page += 1
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        .disabled(!canGoOlder)
        .help("Previous period")
        .accessibilityLabel(Text("Previous period"))
        Text(periodTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
        Button {
          page = max(0, page - 1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .buttonStyle(.borderless)
        .disabled(page == 0)
        .help("Next period")
        .accessibilityLabel(Text("Next period"))
        Spacer(minLength: 12)
        CanvasTabs(options: [("7 days", 7), ("28 days", 28), ("90 days", 90)],
                   selection: $range, label: "Date range")
          .frame(width: 210)
      }
      .onChange(of: range) { _ in page = 0 }
      HStack(spacing: 38) {
        Metric(
          title: "Practice", value: L("%@ hr", number(minutes / 60)))
        Metric(
          title: "Experience", value: "\(number(days.reduce(0) { $0 + $1.xp })) XP")
        Metric(
          title: "Active days", value: "\(days.filter { $0.minutes > 0 }.count)")
      }
      RowDivider()
      CanvasSection(title: "Practice", detail: "Minutes per day") {
        if minutes > 0 {
          PracticeChart(days: days).frame(height: 190)
        } else {
          EmptyState(
            symbol: "chart.bar.xaxis", title: "No sessions in this period", compact: true)
        }
      }
      RowDivider()
      CanvasSection(title: "Discipline", detail: "28-day rolling index") {
        if days.contains(where: { $0.discipline != nil }) {
          Chart(days.filter { $0.discipline != nil }) { day in
            LineMark(x: .value("Day", chartDate(day.day)), y: .value("Index", day.discipline!))
              .interpolationMethod(.monotone).foregroundStyle(AppStyle.mint).lineStyle(
                StrokeStyle(lineWidth: 2.5, lineCap: .round))
          }
          .chartYScale(domain: 0...100).chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 7)) { _ in
              AxisValueLabel(format: .dateTime.month(.abbreviated).day()).font(.system(size: 10))
            }
          }.chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
              AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(
                Color.primary.opacity(0.07))
              AxisValueLabel().font(.system(size: 10))
            }
          }.frame(height: 145)
        } else {
          EmptyState(
            symbol: "checkmark.seal",
            title: "Accept a daily plan or create a routine to start building your discipline history.",
            compact: true
          )
        }
      }
      let totals = minutesBySkill
      if !totals.isEmpty {
        RowDivider()
        CanvasSection(title: "Time by skill") {
          VStack(spacing: 16) {
            ForEach(state.skills.filter { totals[$0.id, default: 0] > 0 }) { skill in
              let skillMinutes = totals[skill.id, default: 0]
              VStack(alignment: .leading, spacing: 8) {
                HStack {
                  Text(skill.displayTitle).font(.system(size: 13, weight: .medium))
                  Spacer()
                  Text(L("%@ min", number(skillMinutes)))
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                ProgressTrack(value: skillMinutes, total: minutes, height: 4)
              }
            }
          }
        }
      }
    }
  }
}

struct JournalView: View {
  @Environment(\.locale) private var locale
  let state: GameState
  @Binding var search: String
  @Binding var tab: Int
  private var entries: [JournalEntry] {
    state.journal.reversed().filter {
      search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
    }
  }
  private var events: [GameEvent] {
    if search.isEmpty { return Array(state.events.reversed()) }
    return state.events.reversed().filter {
      L(eventTitle($0.kind)).localizedCaseInsensitiveContains(search)
        || englishText($0.description).localizedCaseInsensitiveContains(search)
    }
  }
  private func entriesByDay(_ entries: [JournalEntry]) -> [(day: String, entries: [JournalEntry])] {
    Dictionary(grouping: entries, by: \.day)
      .map { (day: $0.key, entries: $0.value) }
      .sorted { $0.day > $1.day }
  }
  var body: some View {
    let _ = locale
    PageFrame {
      journalBody
      .frame(maxWidth: 860)
      .padding(.horizontal, 32)
      .padding(.top, 20)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
  }
  @ViewBuilder private var journalBody: some View {
    if tab == 0 {
      let visible = entries
      if visible.isEmpty {
        EmptyState(
          symbol: search.isEmpty ? "square.and.pencil" : "magnifyingglass",
          title: search.isEmpty ? "No journal entries yet" : "No matching entries",
          buttonTitle: search.isEmpty ? nil : "Clear search"
        ) { search = "" }
        .frame(maxHeight: .infinity, alignment: .top)
      } else {
        let groups = entriesByDay(visible)
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 22) {
            ForEach(groups, id: \.day) { group in
              VStack(alignment: .leading, spacing: 12) {
                if group.day != groups.first?.day { RowDivider() }
                Text(dateText(group.day)).font(.system(size: 12, weight: .medium))
                  .foregroundStyle(.secondary)
                  .accessibilityAddTraits(.isHeader)
                ForEach(group.entries) { entry in
                  Text(entry.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: 680, alignment: .leading)
                }
              }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.vertical, 22)
        }
      }
    } else {
      activity(events)
    }
  }

  @ViewBuilder private func activity(_ events: [GameEvent]) -> some View {
    if events.isEmpty {
      EmptyState(
        symbol: search.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
        title: search.isEmpty ? "No activity yet" : "No matching entries",
        message: search.isEmpty
          ? "Your sessions, milestones, and plan changes will appear here."
          : "Try a different search.",
        buttonTitle: search.isEmpty ? nil : "Clear search"
      ) { search = "" }.frame(maxHeight: .infinity, alignment: .top)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(events) { event in
            DisclosureGroup {
              Text(englishText(event.description)).font(.system(size: 12)).foregroundStyle(
                .secondary
              ).lineSpacing(4).textSelection(.enabled).padding(.top, 8)
            } label: {
              HStack {
                Text(L(eventTitle(event.kind))).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(dateText(event.at)).foregroundStyle(Color.secondary).font(.system(size: 11))
              }
            }.padding(.vertical, 12)
            RowDivider()
          }
        }
      }
    }
  }
  private static let eventTitles = [
    "session_completed": "Session completed", "quest_created": "Quest created",
    "plan_committed": "Plan accepted", "plan_changed": "Plan updated",
    "mastery_verified": "Mastery verified", "checkin": "Check-in updated",
    "target_set": "Weekly goal set", "quest_status": "Quest status changed",
    "profile_created": "Profile created", "import": "Data restored",
    "routine_updated": "Routine updated",
  ]

  private func eventTitle(_ kind: String) -> String {
    Self.eventTitles[kind] ?? "Activity"
  }
}

private let chartDayFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter
}()
func chartDate(_ value: String) -> Date {
  chartDayFormatter.date(from: String(value.prefix(10))) ?? .distantPast
}
