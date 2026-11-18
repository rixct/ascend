import AppKit
import Charts
import SwiftUI

struct Metric: View {
  @Environment(\.locale) private var locale
  let title: String
  let value: String
  var symbol = "sparkles"
  var color: Color = AppStyle.accent
  var body: some View {
    let _ = locale
    Surface(padding: 16) {
      VStack(alignment: .leading, spacing: 12) {
        HStack {
          Text(L(title)).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.secondary)
          Spacer(minLength: 6)
          Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            .frame(width: 24, height: 24).background(
              color.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
        }
        Text(L(value)).font(.system(size: 26, weight: .semibold, design: .rounded))
          .monospacedDigit()
          .lineLimit(1).minimumScaleFactor(0.7)
      }
    }
  }
}

struct DashboardView: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  let state: GameState
  let summary: Summary
  var body: some View {
    let _ = locale
    ScreenLayout {
      HStack(spacing: 14) {
        Metric(
          title: "Practice today",
          value:
            L(
              "%d min",
              state.sessions.filter { $0.day == summary.today }.reduce(0) { $0 + $1.seconds } / 60),
          symbol: "clock", color: AppStyle.blue)
          .frame(maxWidth: .infinity, alignment: .leading)
        Metric(
          title: "Discipline",
          value: summary.discipline.map {
            (summary.preliminary ? "≈" : "") + String(Int($0.rounded()))
          } ?? "—", symbol: "checkmark.seal", color: AppStyle.mint)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      HStack(alignment: .top, spacing: 20) {
        SectionCard(title: "Practice", fillHeight: true) {
          TimerView(state: state, summary: summary).frame(
            maxHeight: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        DailyRoutineCard(summary: summary)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }.fixedSize(horizontal: false, vertical: true)
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
  @State private var hoveredQuest: String?
  var body: some View {
    let _ = locale
    VStack(alignment: .leading, spacing: 18) {
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
        Text(clock(active.elapsed_seconds)).font(
          .system(size: 50, weight: .light, design: .rounded)
        ).monospacedDigit().contentTransition(.identity)
        if let quest = state.quest(active.quest_id) {
          ProgressTrack(
            value: Double(active.elapsed_seconds), total: Double(quest.estimate_minutes * 60))
        }
        TextField("Add a session note", text: $notes).textFieldStyle(.roundedBorder).controlSize(
          .large
        )
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
          }.controlSize(.large)
          Button {
            confirmCancel = true
          } label: {
            Label("Cancel session", systemImage: "xmark")
          }.controlSize(.large)
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
          Button {
            confirmReset = true
          } label: {
            Label("Reset timer", systemImage: "arrow.counterclockwise")
          }.controlSize(.large)
          Button("Finish session") { store.finish() }.buttonStyle(.borderedProminent).controlSize(
            .large)
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
            message: "Add something you start with a timer. A check without a timer belongs in the routine.",
            buttonTitle: "Create a quest", compact: true
          ) { store.sheet = .quest }
        } else {
          VStack(alignment: .leading, spacing: 12) {
            ForEach(practices) { quest in
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
    let progress =
      quest.kind == "Habit"
      ? L("%d min", quest.estimate_minutes)
      : L("%d of %d", saved, quest.sessionTarget)
    return HStack(alignment: .center, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text(quest.title)
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(done ? Color.secondary : Color.primary)
          .fixedSize(horizontal: false, vertical: true)
        Text(verbatim: "\(state.skill(quest.skill_id)) · \(quest.kindName) · \(progress)")
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
      } else if hoveredQuest == quest.id, store.available(quest) {
        Button {
          store.startSession(quest.id)
        } label: {
          Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 28, height: 22)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .disabled(!store.canStart || store.busy)
        .accessibilityLabel("Start")
        .help("Start")
      }
    }
    .padding(.vertical, 2)
    .contentShape(Rectangle())
    .background {
      RowHover { hovering in
        if hovering {
          hoveredQuest = quest.id
        } else if hoveredQuest == quest.id {
          hoveredQuest = nil
        }
      }
    }
    .accessibilityAction(named: Text("Start")) {
      guard !done, store.available(quest), store.canStart, !store.busy else { return }
      store.startSession(quest.id)
    }
  }
}

private struct RowHover: NSViewRepresentable {
  var changed: (Bool) -> Void
  func makeNSView(context: Context) -> RowHoverView {
    let view = RowHoverView()
    view.changed = changed
    return view
  }
  func updateNSView(_ view: RowHoverView, context: Context) {
    view.changed = changed
  }
}

private final class RowHoverView: NSView {
  var changed: (Bool) -> Void = { _ in }
  private var inside = false
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(
      NSTrackingArea(
        rect: bounds,
        options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
        owner: self,
        userInfo: nil))
  }
  override func mouseEntered(with event: NSEvent) {
    guard !inside else { return }
    inside = true
    changed(true)
  }
  override func mouseExited(with event: NSEvent) {
    guard inside else { return }
    inside = false
    changed(false)
  }
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window == nil, inside else { return }
    inside = false
    changed(false)
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
      Surface(padding: 30) { TimerView(state: state, summary: summary) }
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
      Surface(padding: 0, fillHeight: true) {
        GeometryReader { geo in
          let total = geo.size.width
          let gap: CGFloat = 9
          let left = leftWidth(total: total, gap: gap)
          HStack(spacing: 0) {
            profile.frame(width: left)
            divider(total: total, gap: gap)
            attributes.frame(maxWidth: .infinity, maxHeight: .infinity)
          }
          .coordinateSpace(name: "character-split")
          .frame(width: total, height: geo.size.height, alignment: .leading)
        }
      }
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .padding(24)
      .frame(
        minWidth: ProfileColumn.minPane + 9 + ProfileColumn.minChart,
        maxWidth: .infinity, minHeight: 540, maxHeight: .infinity, alignment: .top
      )
    }
  }
  private var profile: some View {
    HStack(alignment: .top, spacing: ProfileColumn.spacing) {
      ProfileAvatar(encodedImage: state.settings.avatar, size: ProfileColumn.avatar)
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(state.settings.name)
            .font(.system(size: 24, weight: .semibold))
            .lineLimit(1)
          Spacer(minLength: 8)
          StatusPill(title: L("Level %d", summary.level), symbol: "sparkles")
            .fixedSize()
        }
        ProgressTrack(value: summary.level_xp, total: summary.next_xp, height: 7)
        HStack(spacing: 12) {
          Text(L("%@ total XP", number(Double(state.character_xp_milli) / 1000)))
            .lineLimit(1)
          Spacer(minLength: 8)
          Text("\(number(summary.level_xp)) / \(number(summary.next_xp)) XP")
            .lineLimit(1)
            .fixedSize()
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.secondary)
      }
      .frame(width: ProfileColumn.text, alignment: .leading)
    }
    .padding(ProfileColumn.padding)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
  }
  private var attributes: some View {
    VStack(alignment: .leading, spacing: 8) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
  static let text: CGFloat = 292
  static let avatar: CGFloat = 84
  static let spacing: CGFloat = 18
  static let padding: CGFloat = 28
  static var minPane: CGFloat { padding * 2 + avatar + spacing + text }
  static let minChart: CGFloat = 360
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
      let radius = min(geo.size.width, geo.size.height) * 0.30
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
          for index in 0..<6 {
            let point = vertex(
              center: center, radius: radius, index: index, scale: spokes[index].value / 100)
            let dot = Path(
              ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            context.fill(dot, with: .color(AppStyle.accent))
          }
        }
        ForEach(0..<6, id: \.self) { index in
          let point = vertex(center: center, radius: radius + 42, index: index, scale: 1)
          VStack(spacing: 2) {
            Text(englishName(spokes[index].name))
              .font(.system(size: 11, weight: .medium))
              .multilineTextAlignment(.center)
              .lineLimit(2)
            Text("\(Int(spokes[index].value.rounded()))")
              .font(.system(size: 12, weight: .semibold, design: .rounded))
              .foregroundStyle(.secondary)
          }
          .frame(width: 108)
          .position(point)
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
          Surface {
            EmptyState(
              symbol: "point.3.connected.trianglepath.dotted",
              title: "What would you like to get better at?",
              message:
                "Add a skill you want to develop. Your practice and milestones will grow from there.",
              buttonTitle: "Add a skill"
            ) { store.sheet = .skill }
          }
        } else {
          skillsSplit
        }
      }
      .padding(24)
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
    Surface(padding: 0) {
      HStack(spacing: 0) {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(state.skills) { skill in skillRow(skill) }
          }
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 280)
        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
        if let skill = state.skills.first(where: { $0.id == selected }) ?? state.skills.first {
          ScrollView {
            VStack(alignment: .leading, spacing: 22) {
              Surface {
                VStack(alignment: .leading, spacing: 18) {
                  HStack {
                    Text(skill.displayTitle).font(.system(size: 23, weight: .semibold))
                    Spacer()
                    PencilButton(label: "Edit skill") { store.sheet = .editSkill(skill.id) }
                      .disabled(store.busy)
                    if !summary.unlocked_skills.contains(skill.id) {
                      StatusPill(title: "Locked", color: .secondary, symbol: "lock.fill")
                    }
                  }
                  HStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 5) {
                      Text("Experience").font(.system(size: 11)).foregroundStyle(Color.secondary)
                      Text("\(number(Double(skill.xp_milli) / 1000)) XP").font(
                        .system(size: 21, weight: .semibold, design: .rounded))
                    }
                    VStack(alignment: .leading, spacing: 5) {
                      Text("Verified milestones").font(.system(size: 11)).foregroundStyle(
                        Color.secondary)
                      Text("\(skill.mastery)").font(
                        .system(size: 21, weight: .semibold, design: .rounded))
                    }
                  }
                  if !skill.prerequisites.isEmpty {
                    Label(
                      skill.prerequisites.map { state.skill($0) }.joined(separator: ", "),
                      systemImage: "arrow.turn.down.right"
                    ).font(.system(size: 12)).foregroundStyle(Color.secondary)
                  }
                  Text(FocusList.summary(skill))
                  .font(.system(size: 12)).foregroundStyle(Color.secondary).fixedSize(
                    horizontal: false, vertical: true)
                  HStack(spacing: 8) {
                    Button("Verify mastery…") { store.sheet = .mastery(skill.id) }.buttonStyle(
                      .borderedProminent
                    ).controlSize(.large).disabled(!state.canVerifySkill(skill.id, summary: summary))
                    if !state.skillQuestsCompleted(skill.id) {
                      HintButton(text: "Complete all quests to verify this skill.")
                    }
                  }
                }
              }
              SectionCard(title: "Verified outcomes") {
                if skill.evidence.isEmpty {
                  EmptyState(
                    symbol: "checkmark.seal", title: "Let your work speak",
                    message: "Verified outcomes will appear here as your skill develops.",
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
              SectionCard(title: "Recent practice") {
                let sessions = Array(
                  state.sessions.filter { $0.skill_id == skill.id }.suffix(8).reversed())
                if sessions.isEmpty {
                  EmptyState(
                    symbol: "clock", title: "Your first session is ahead",
                    message: "Practice linked to this skill will appear here.", compact: true)
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
            .padding(22)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .foregroundStyle(open ? Color.white.opacity(0.85) : Color.secondary)
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
              .foregroundStyle(open ? Color.white : AppStyle.accent)
            }
            Image(
              systemName: summary.unlocked_skills.contains(skill.id) ? "circle.hexagongrid" : "lock"
            )
            .font(.system(size: 14, weight: .light))
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
              Text(skill.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
              Text("\(number(Double(skill.xp_milli) / 1000)) XP").font(.system(size: 11))
            }
            Spacer(minLength: 0)
            if skill.mastery > 0 {
              Image(systemName: "checkmark.seal.fill").font(.system(size: 12))
            }
          }
          .foregroundStyle(open ? Color.white : Color.primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(open ? AppStyle.accent : Color.clear)
      }
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
  @State private var selected: String?
  @State private var expanded = Set<String>()
  @State private var filter = 0
  @State private var search = ""
  private var quests: [Quest] {
    state.quests.reversed().filter {
      (filter == 2 || (filter == 0 ? !$0.closed : $0.closed))
        && (search.isEmpty || $0.title.localizedCaseInsensitiveContains(search))
    }
  }
  var body: some View {
    let _ = locale
    PageFrame {
      Group {
        if state.quests.isEmpty {
          Surface {
            EmptyState(
              symbol: "checklist", title: "One clear next step",
              message: "Turn something you want to do into a quest with a clear outcome.",
              buttonTitle: "Create a quest"
            ) { store.sheet = .quest }
          }
        } else {
          questSplit
        }
      }
      .padding(24)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .onAppear { if selected == nil { selected = quests.first?.id } }
    .onChange(of: quests.map(\.id)) { ids in
      if selected == nil || !ids.contains(selected ?? "") { selected = ids.first }
    }
  }
  private var questSplit: some View {
    let practice = QuestPractice.totals(state.sessions)
    return Surface(padding: 0) {
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          VStack(spacing: 10) {
            Picker("", selection: $filter) {
              Text("Active").tag(0)
              Text("Closed").tag(1)
              Text("All").tag(2)
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("Quest status")
            HStack(spacing: 7) {
              Image(systemName: "magnifyingglass").foregroundStyle(Color.secondary)
              TextField("Search quests", text: $search).textFieldStyle(.plain)
            }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 8).background(
              Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
          }.padding(12)
          RowDivider()
          if quests.isEmpty {
            EmptyState(
              symbol: search.isEmpty ? "checklist" : "magnifyingglass",
              title: search.isEmpty
                ? (filter == 1 ? "Nothing closed out yet" : "One clear next step")
                : "No matching quests",
              message: search.isEmpty
                ? (filter == 1
                  ? "Completed and cancelled quests will be kept here."
                  : "Turn something you want to do into a quest with a clear outcome.")
                : "Try a different search or browse all your quests.",
              buttonTitle: search.isEmpty ? (filter == 1 ? nil : "Create a quest") : "Clear search"
            ) {
              if search.isEmpty {
                store.sheet = .quest
              } else {
                search = ""
                filter = 2
              }
            }
          } else {
            ScrollView {
              LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(quests) { quest in questRow(quest) }
              }
              .padding(12)
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
        Group {
          if let quest = quests.first(where: { $0.id == selected }) ?? quests.first {
            questDetail(quest, practice: practice)
          }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
  private func questDetail(_ quest: Quest, practice: [String: QuestPractice]) -> some View {
    let saved = practice[quest.id] ?? QuestPractice()
    return ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Surface {
          VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
              Text(quest.title).font(.system(size: 23, weight: .semibold)).fixedSize(
                horizontal: false, vertical: true)
              Spacer(minLength: 12)
              PencilButton(label: "Edit quest") { store.sheet = .editQuest(quest.id) }
                .disabled(store.busy)
              StatusPill(
                title: summary.unlocked_quests.contains(quest.id) ? quest.statusName : "Locked",
                color: quest.status == "Completed"
                  ? AppStyle.mint : quest.status == "Active" ? AppStyle.accent : .secondary)
            }
            if !quest.outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
              Text(quest.outcome).font(.system(size: 13)).foregroundStyle(Color.secondary)
                .lineSpacing(3).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
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
            HStack(spacing: 10) {
              if let deadline = quest.deadline {
                Label(dateText(deadline), systemImage: "calendar").font(.system(size: 12))
                  .foregroundStyle(Color.secondary)
              }
              Spacer()
              if store.available(quest) {
                if !store.strictLogging {
                  Button("Log time…") { store.finish(quest) }.controlSize(.large).disabled(
                    !store.canStart)
                }
                Button {
                  store.startSession(quest.id)
                } label: {
                  Label("Start session", systemImage: "play.fill")
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!store.canStart)
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
                  Image(systemName: "ellipsis")
                }.fixedSize().controlSize(.large)
              }
            }
          }
        }
      }
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func detailMetric(_ title: LocalizedStringKey, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.system(size: 11)).foregroundStyle(Color.secondary)
      Text(value).font(.system(size: 16, weight: .semibold)).lineLimit(2)
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
        .foregroundStyle(chosen ? Color.white.opacity(0.85) : Color.secondary)
        .accessibilityLabel(Text("Steps"))
        Button {
          selected = quest.id
        } label: {
          HStack(spacing: 8) {
            Image(
              systemName: quest.kind == "Habit"
                ? "arrow.clockwise" : quest.kind == "Project" ? "flag" : "circle.dotted"
            )
            .font(.system(size: 14, weight: .light))
            .frame(width: 18)
            .foregroundStyle(chosen ? Color.white.opacity(0.9) : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
              Text(quest.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
              Text(state.skill(quest.skill_id)).font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(chosen ? Color.white.opacity(0.78) : Color.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: mark.symbol)
              .font(.system(size: 12, weight: .medium))
              .foregroundStyle(chosen ? Color.white.opacity(0.9) : mark.color)
          }
          .foregroundStyle(chosen ? Color.white : Color.primary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .background {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(chosen ? AppStyle.accent : Color.clear)
      }
      if shown {
        QuestStepsEditor(quest: quest, showsHeading: false)
          .padding(.leading, 32)
          .padding(.trailing, 8)
          .padding(.vertical, 4)
      }
    }
  }
  private func questMark(_ quest: Quest) -> (symbol: String, color: Color) {
    if quest.status == "Completed" { return ("checkmark", AppStyle.mint) }
    let overdue =
      quest.status == "Missed"
      || (quest.deadline.map { $0 < summary.today } ?? false && quest.status != "Cancelled")
    if overdue { return ("xmark", Color(red: 0.86, green: 0.35, blue: 0.32)) }
    if quest.status == "Paused" { return ("pause", Color.secondary) }
    if quest.status == "Active" { return ("play.fill", AppStyle.accent) }
    return ("circle", Color.secondary)
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
    ScreenLayout {
      Surface {
        HStack(spacing: 18) {
          Image(systemName: "leaf").font(.system(size: 24, weight: .light)).foregroundStyle(
            AppStyle.mint
          ).frame(width: 52, height: 52).background(
            AppStyle.mint.opacity(0.09), in: RoundedRectangle(cornerRadius: 15))
          VStack(alignment: .leading, spacing: 6) {
            Text("Suggested workload").font(.system(size: 11)).foregroundStyle(Color.secondary)
            Text(englishText(summary.recommendation)).font(.system(size: 17, weight: .semibold))
          }
          Spacer()
          Text("\(summary.suggested_minutes)").font(
            .system(size: 29, weight: .semibold, design: .rounded)
          ).monospacedDigit() + Text(L(" min")).font(.system(size: 13)).foregroundColor(.secondary)
        }.padding(.trailing, 28)
          .overlay(alignment: .topTrailing) {
            Button {
              explanation.toggle()
            } label: {
              Image(systemName: "info.circle").foregroundStyle(Color.secondary)
            }.buttonStyle(.plain).help("About your rhythm").popover(isPresented: $explanation) {
              Text(englishText(summary.recommendation_detail)).font(.system(size: 13)).lineSpacing(
                4
              )
              .frame(width: 330).padding(22)
            }
          }
      }
      SectionCard(
        title: "This week", detail: summary.balance.map { L("%d%% complete", Int($0.rounded())) }
      ) {
        if targets.isEmpty {
          EmptyState(
            symbol: "scope", title: "Give your week a direction",
            message: "Set a target for a skill you want to develop.",
            buttonTitle: "Add a weekly goal"
          ) { store.sheet = .target }
        } else {
          VStack(spacing: 22) { ForEach(targets) { target in targetRow(target) } }
        }
      }
      SectionCard(
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
            symbol: "sun.horizon", title: "How are you feeling?",
            message: "A quick check-in helps shape a realistic plan for today.",
            buttonTitle: "Check in", compact: true
          ) { store.sheet = .checkin }
        }
      }
      if state.targets.contains(where: { $0.week > summary.week }) {
        SectionCard(title: "Next week") {
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
        width: .ratio(0.55)
      )
      .foregroundStyle(AppStyle.accent.gradient).cornerRadius(4)
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
    ScreenLayout {
      HStack(spacing: 10) {
        Text("Your progress").font(.system(size: 23, weight: .semibold))
        Spacer(minLength: 12)
        Button {
          page += 1
        } label: {
          Image(systemName: "chevron.left")
        }
        .buttonStyle(.borderless)
        .disabled(!canGoOlder)
        .help("Previous period")
        .accessibilityLabel(Text("Previous period"))
        Text(periodTitle).font(.system(size: 12)).foregroundStyle(.secondary)
          .lineLimit(1)
          .frame(minWidth: 150)
        Button {
          page = max(0, page - 1)
        } label: {
          Image(systemName: "chevron.right")
        }
        .buttonStyle(.borderless)
        .disabled(page == 0)
        .help("Next period")
        .accessibilityLabel(Text("Next period"))
        Picker("", selection: $range) {
          Text("7 days").tag(7)
          Text("28 days").tag(28)
          Text("90 days").tag(90)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 260).accessibilityLabel("Date range")
      }
      .onChange(of: range) { _ in page = 0 }
      HStack(spacing: 14) {
        Metric(
          title: "Practice", value: L("%@ hr", number(minutes / 60)), symbol: "clock",
          color: AppStyle.blue)
        Metric(
          title: "Experience", value: "\(number(days.reduce(0) { $0 + $1.xp })) XP",
          symbol: "sparkles")
        Metric(
          title: "Active days", value: "\(days.filter { $0.minutes > 0 }.count)",
          symbol: "calendar.badge.checkmark", color: AppStyle.mint)
      }
      SectionCard(title: "Practice", detail: "Minutes per day") {
        if minutes > 0 {
          PracticeChart(days: days).frame(height: 190)
        } else {
          EmptyState(
            symbol: "chart.bar.xaxis", title: "No sessions in this period",
            message: "Nothing was logged in this period.", compact: true)
        }
      }
      SectionCard(title: "Discipline", detail: "28-day rolling index") {
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
            symbol: "checkmark.seal", title: "Consistency takes a little time",
            message: "Accept a daily plan or create a routine to start building your discipline history.", compact: true
          )
        }
      }
      SectionCard(title: "Time by skill") {
        if minutes == 0 {
          EmptyState(
            symbol: "circle.hexagongrid", title: "Nothing to compare just yet",
            message: "Your practice will be grouped here by skill.", compact: true)
        } else {
          let totals = minutesBySkill
          VStack(spacing: 20) {
            ForEach(state.skills) { skill in
              let skillMinutes = totals[skill.id, default: 0]
              if skillMinutes > 0 {
                VStack(alignment: .leading, spacing: 10) {
                  HStack {
                    Text(skill.displayTitle).font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(L("%@ min", number(skillMinutes))).font(.system(size: 12)).foregroundStyle(
                      .secondary)
                  }
                  ProgressTrack(value: skillMinutes, total: minutes)
                }
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
  @EnvironmentObject var store: Store
  let state: GameState
  @State private var tab = 0
  @State private var search = ""
  private var entries: [JournalEntry] {
    state.journal.reversed().filter {
      search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
    }
  }
  private var events: [GameEvent] {
    state.events.reversed().filter {
      let title = L(eventTitle($0.kind))
      return search.isEmpty || title.localizedCaseInsensitiveContains(search)
        || englishText($0.description).localizedCaseInsensitiveContains(search)
    }
  }
  var body: some View {
    let _ = locale
    PageFrame {
      VStack(alignment: .leading, spacing: 0) {
        Surface(padding: 0) {
          VStack(spacing: 0) {
            HStack(spacing: 16) {
              Picker("", selection: $tab) {
                Text("Entries").tag(0)
                Text("Activity").tag(1)
              }.pickerStyle(.segmented).labelsHidden().frame(width: 240, alignment: .leading)
                .accessibilityLabel("Journal filter")
              Spacer(minLength: 12)
              HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.secondary)
                TextField("Search journal", text: $search).textFieldStyle(.plain)
              }.font(.system(size: 12)).padding(.horizontal, 10).padding(.vertical, 8).background(
                Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8)
              ).frame(width: 210)
            }.padding(18)
            RowDivider()
            journalBody
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
      }.padding(24)
    }
  }
  @ViewBuilder private var journalBody: some View {
    if tab == 0 {
      if entries.isEmpty {
        EmptyState(
          symbol: search.isEmpty ? "square.and.pencil" : "magnifyingglass",
          title: search.isEmpty ? "Make a note of what mattered" : "No matching entries",
          message: search.isEmpty
            ? "Capture a win, a lesson, or an idea for tomorrow."
            : "Try a different search.",
          buttonTitle: search.isEmpty ? nil : "Clear search"
        ) { search = "" }.frame(maxHeight: .infinity)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries)) { entry in
              VStack(alignment: .leading, spacing: 6) {
                Text(dateText(entry.day)).font(.system(size: 11, weight: .medium)).foregroundStyle(
                  Color.secondary)
                Text(entry.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }.padding(.horizontal, 18).padding(.vertical, 14)
              RowDivider()
            }
          }
        }
      }
    } else if events.isEmpty {
      EmptyState(
        symbol: search.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass",
        title: search.isEmpty ? "A fresh start" : "No matching entries",
        message: search.isEmpty
          ? "Your sessions, milestones, and plan changes will appear here."
          : "Try a different search.",
        buttonTitle: search.isEmpty ? nil : "Clear search"
      ) { search = "" }.frame(maxHeight: .infinity)
    } else {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 0) {
          ForEach(Array(events)) { event in
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
            }.padding(.horizontal, 18).padding(.vertical, 12)
            RowDivider()
          }
        }
      }
    }
  }
  private func eventTitle(_ kind: String) -> String {
    [
      "session_completed": "Session completed", "quest_created": "Quest created",
      "plan_committed": "Plan accepted", "plan_changed": "Plan updated",
      "mastery_verified": "Mastery verified", "checkin": "Check-in updated",
      "target_set": "Weekly goal set", "quest_status": "Quest status changed",
      "profile_created": "Profile created", "import": "Data restored",
      "routine_updated": "Routine updated",
    ][kind] ?? "Activity"
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
