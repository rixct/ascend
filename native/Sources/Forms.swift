import SwiftUI

extension Notification.Name { static let ascendSave = Notification.Name("dev.ascend.save") }

struct SheetView: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  let sheet: Sheet
  var body: some View {
    let _ = locale
    Group {
      switch sheet {
      case .quest: QuestForm()
      case .editQuest(let id): QuestForm(questID: id)
      case .startSession(let id): SessionStartView(questID: id)
      case .skill: SkillForm()
      case .editSkill(let id): SkillForm(skillID: id)
      case .target: TargetForm()
      case .mastery(let id):
        TextEntryForm(
          title: "Verify mastery", label: "Outcome", command: "verify", id: id)
      case .journal:
        TextEntryForm(title: "Journal entry", label: "Text", command: "journal", id: nil)
      case .finish(let id, let quest, let seconds, let notes):
        FinishForm(id: id, quest: quest, seconds: seconds, notes: notes)
      case .plan: PlanForm()
      case .excuse(let id): ExcuseForm(id: id)
      case .checkin: CheckInForm()
      case .milestones:
        if let state = store.state {
          MilestonesSheet(state: state)
        }
      }
    }
    .alert(
      L("Unable to save"),
      isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button(L("OK")) { store.error = nil }
    } message: {
      Text(englishText(store.error ?? ""))
    }
  }
}

struct SheetShell<Content: View>: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  let title: String
  var actionTitle = "Save"
  var valid = true
  var height: CGFloat = 320
  let save: () -> Void
  @ViewBuilder let content: () -> Content
  var body: some View {
    let _ = locale
    VStack(alignment: .leading, spacing: 0) {
      Text(L(title)).font(.system(size: 21, weight: .semibold)).padding(.horizontal, 26).padding(
        .top, 26
      ).padding(.bottom, 18)
      Form { content() }.toggleStyle(TrailingSwitchStyle()).formStyle(.grouped).controlSize(.large)
        .frame(height: height)
      Divider()
      HStack {
        Spacer()
        Button(L("Cancel")) { store.sheet = nil }.controlSize(.large).keyboardShortcut(
          .cancelAction)
        Button(L(actionTitle), action: save).controlSize(.large).buttonStyle(.borderedProminent)
          .keyboardShortcut(
            .defaultAction
          ).disabled(!valid || store.busy)
      }.padding(.horizontal, 24).padding(.vertical, 18)
    }.frame(width: 530)
      .onReceive(NotificationCenter.default.publisher(for: .ascendSave)) { _ in
        if valid && !store.busy { save() }
      }
  }
}

private struct DraftStep: Identifiable, Equatable {
  var id = UUID().uuidString
  var title = ""
  var done = false
}

struct QuestForm: View {
  var questID: String? = nil
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  @State private var title = ""
  @State private var outcome = ""
  @State private var skill = ""
  @State private var kind = "Daily"
  @State private var minutes = 25
  @State private var sessions = 1
  @State private var steps: [DraftStep] = []
  private var sessionMinimum: Int { kind == "Habit" ? 7 : 1 }
  private var sessionMaximum: Int { kind == "Habit" ? 365 : 10000 }
  @State private var priority = 2
  @State private var difficulty = 1.0
  @State private var bonus = 0
  @State private var deadline = Date()
  @State private var hasDeadline = false
  @State private var dependency = ""
  @State private var advanced = false
  @State private var keepLoadedSessions = false
  var body: some View {
    let _ = locale
    SheetShell(
      title: questID == nil ? "New quest" : "Edit quest",
      actionTitle: questID == nil ? "Create" : "Save",
      valid: !title.trimmingCharacters(in: .whitespaces).isEmpty && !skill.isEmpty
        && (1...1440).contains(minutes)
        && (sessionMinimum...sessionMaximum).contains(sessions),
      height: formHeight, save: save
    ) {
      Section {
        TextField("Title", text: $title)
        TextField("Outcome", text: $outcome)
        Text("Steps").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
        ForEach($steps) { $step in
          HStack(spacing: 8) {
            Toggle(isOn: $step.done) { Text(verbatim: "") }
              .toggleStyle(.checkbox)
              .labelsHidden()
            TextField("Step", text: $step.title)
            Button {
              let id = step.id
              steps.removeAll { $0.id == id }
            } label: {
              Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove step")
          }
        }
        Button("Add a step") {
          guard steps.count < 24 else { return }
          steps.append(DraftStep())
        }
        .disabled(steps.count >= 24)
        if skillLocked {
          LabeledContent("Skill") {
            HStack(spacing: 5) {
              Text(verbatim: selectedSkillTitle).foregroundStyle(.secondary)
              HintButton(text: "Saved sessions keep this skill.")
            }
          }
        } else {
          choiceRow("Skill", value: Text(verbatim: selectedSkillTitle)) {
            ForEach(store.state?.skills ?? []) { item in
              menuChoice(selected: skill == item.id, title: Text(verbatim: item.displayTitle)) {
                skill = item.id
              }
            }
          }
        }
        choiceRow("How it repeats", value: Text(kindLabel)) {
          menuChoice(selected: kind == "Daily", title: Text("Until it's done")) { kind = "Daily" }
          menuChoice(selected: kind == "Project", title: Text("One step")) { kind = "Project" }
          menuChoice(selected: kind == "Habit", title: Text("Every day")) { kind = "Habit" }
        }
        Text(kindHint)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        choiceRow("Depends on", value: dependencyLabel) {
          menuChoice(selected: dependency.isEmpty, title: Text("None")) { dependency = "" }
          Section("This skill") {
            ForEach(dependencyQuests(sameSkill: true)) { quest in
              menuChoice(selected: dependency == quest.id, title: Text(verbatim: quest.title)) {
                dependency = quest.id
              }
            }
          }
          Section("Other skills") {
            ForEach(dependencyQuests(sameSkill: false)) { quest in
              menuChoice(
                selected: dependency == quest.id,
                title: Text(verbatim: "\(quest.title) · \(store.state?.skill(quest.skill_id) ?? "")")
              ) { dependency = quest.id }
            }
          }
        }
        TextField("Minutes per session", value: $minutes, format: .number)
        PlannedSessionInput(
          title: kind == "Habit" ? "Days to establish" : "Planned sessions",
          value: $sessions, minimum: sessionMinimum, maximum: sessionMaximum
        )
        choiceRow("Priority", value: Text(priorityLabel)) {
          menuChoice(selected: priority == 1, title: Text("Low")) { priority = 1 }
          menuChoice(selected: priority == 2, title: Text("Normal")) { priority = 2 }
          menuChoice(selected: priority == 3, title: Text("High")) { priority = 3 }
        }
        Button {
          advanced.toggle()
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
              .rotationEffect(.degrees(advanced ? 90 : 0))
              .foregroundStyle(.secondary)
            Text("Advanced options")
            Spacer(minLength: 0)
          }
          .padding(.vertical, 6)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if advanced {
          choiceRow("Difficulty", value: Text(difficultyLabel)) {
            menuChoice(selected: difficulty == 0.5, title: Text("Easy")) { difficulty = 0.5 }
            menuChoice(selected: difficulty == 1, title: Text("Standard")) { difficulty = 1 }
            menuChoice(selected: difficulty == 1.5, title: Text("Hard")) { difficulty = 1.5 }
            menuChoice(selected: difficulty == 2, title: Text("Demanding")) { difficulty = 2 }
          }
          if kind == "Project" {
            LabeledContent {
              TextField("Bonus XP", value: $bonus, format: .number).labelsHidden()
            } label: {
              HStack(spacing: 5) {
                Text("Bonus XP")
                HintButton(
                  text: "Paid when every planned session is done, and never more than the practice XP earned on this milestone."
                )
              }
            }
          }
          Toggle("Due date", isOn: $hasDeadline)
          if hasDeadline {
            DatePicker("Date", selection: $deadline, displayedComponents: .date)
          }
        }
      }
    }
    .onAppear(perform: load)
    .onChange(of: skill) { id in
      if store.state?.skills.first(where: { $0.id == id })?.domain == "Recovery" { kind = "Habit" }
    }
    .onChange(of: kind) { value in
      if keepLoadedSessions {
        keepLoadedSessions = false
        return
      }
      let lower = value == "Habit" ? 7 : 1
      let upper = value == "Habit" ? 365 : 10000
      sessions = min(upper, max(lower, value == "Habit" && sessions == 1 ? 7 : sessions))
    }
  }
  private var formHeight: CGFloat {
    var height: CGFloat = advanced ? 564 : 458
    if advanced && kind == "Project" { height += 46 }
    if advanced && hasDeadline { height += 46 }
    height += 36 + CGFloat(min(steps.count, 4)) * 32
    return min(height, 740)
  }
  private var skillLocked: Bool {
    guard let questID else { return false }
    return store.state?.sessions.contains { $0.quest_id == questID } == true
  }
  private func load() {
    if let questID, let quest = store.state?.quests.first(where: { $0.id == questID }) {
      title = quest.title
      outcome = quest.outcome
      skill = quest.skill_id
      sessions = quest.sessionTarget
      if quest.kind != kind { keepLoadedSessions = true }
      kind = quest.kind
      minutes = quest.estimate_minutes
      priority = quest.priority
      difficulty = quest.difficulty
      bonus = Int(quest.bonus_milli / 1000)
      dependency = quest.dependencies.first ?? ""
      if store.state?.quests.contains(where: { $0.id == dependency }) != true { dependency = "" }
      steps = quest.questSteps.map { DraftStep(id: $0.id, title: $0.title, done: $0.done) }
      if let raw = quest.deadline {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        if let date = formatter.date(from: raw) {
          deadline = date
          hasDeadline = true
        }
      }
      advanced = hasDeadline || quest.difficulty != 1 || quest.bonus_milli > 0
      return
    }
    skill =
      store.questDraftSkill.flatMap { id in
        store.state?.skills.contains(where: { $0.id == id }) == true ? id : nil
      }
      ?? store.state?.skills.first?.id ?? ""
    dependency = store.questDraftPrerequisite ?? ""
    store.questDraftSkill = nil
    store.questDraftPrerequisite = nil
  }
  private var selectedSkillTitle: String {
    store.state?.skills.first { $0.id == skill }?.displayTitle ?? ""
  }
  private var kindLabel: LocalizedStringKey {
    switch kind {
    case "Project": "One step"
    case "Habit": "Every day"
    default: "Until it's done"
    }
  }
  private var kindHint: LocalizedStringKey {
    switch kind {
    case "Project": "A larger goal. Bonus XP, if you set any, arrives when every session is done."
    case "Habit": "Start it once today. Tomorrow it is ready again."
    default: "Each start counts as one session toward the plan."
    }
  }
  private var priorityLabel: LocalizedStringKey {
    switch priority {
    case 1: "Low"
    case 3: "High"
    default: "Normal"
    }
  }
  private var difficultyLabel: LocalizedStringKey {
    switch difficulty {
    case 0.5: "Easy"
    case 1.5: "Hard"
    case 2: "Demanding"
    default: "Standard"
    }
  }
  private var dependencyLabel: Text {
    guard !dependency.isEmpty, let quest = store.state?.quests.first(where: { $0.id == dependency })
    else { return Text("None") }
    return Text(verbatim: quest.title)
  }
  private func dependencyQuests(sameSkill: Bool) -> [Quest] {
    (store.state?.quests ?? []).filter {
      $0.id != questID && ($0.skill_id == skill) == sameSkill
        && !["Cancelled", "Missed"].contains($0.status)
    }
  }
  private func choiceRow(
    _ title: LocalizedStringKey, value: Text, @ViewBuilder menu: @escaping () -> some View
  ) -> some View {
    LabeledContent(title) { CapsuleMenu(label: value, content: menu) }
  }
  private func menuChoice(selected: Bool, title: Text, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: "checkmark")
          .font(.system(size: 12, weight: .semibold))
          .opacity(selected ? 1 : 0)
          .frame(width: 14)
        title
      }
    }
  }
  private func save() {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    let payload: [[String: Any]] = steps.compactMap { step in
      let name = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !name.isEmpty else { return nil }
      return ["id": step.id, "title": name, "done": step.done]
    }
    store.saveQuest(
      id: questID, title: title, outcome: outcome, skillID: skill, kind: kind, priority: priority,
      minutes: minutes, sessions: sessions, difficulty: difficulty, bonus: bonus,
      deadline: hasDeadline ? formatter.string(from: deadline) : nil,
      dependencies: PrimaryDependency.updating(
        store.state?.quests.first { $0.id == questID }?.dependencies ?? [], selected: dependency
      ), steps: payload
    ) { store.sheet = nil }
  }
}

struct QuestStepsEditor: View {
  @EnvironmentObject private var store: Store
  let quest: Quest
  var showsHeading = true
  @State private var steps: [QuestStep] = []
  @State private var draft = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if showsHeading {
        Text("Steps").font(.system(size: 13, weight: .semibold))
      }
      ForEach(steps) { step in
        HStack(spacing: 8) {
          Toggle(
            isOn: Binding(
              get: { step.done },
              set: { done in
                guard let index = steps.firstIndex(where: { $0.id == step.id }) else { return }
                var next = steps
                next[index].done = done
                commit(next)
              })
          ) {
            Text(verbatim: step.title)
              .font(.system(size: 13))
              .strikethrough(step.done, color: .secondary)
              .foregroundStyle(step.done ? Color.secondary : Color.primary)
          }
          .toggleStyle(.checkbox)
          .disabled(store.busy)
          Spacer(minLength: 8)
          Button {
            commit(steps.filter { $0.id != step.id })
          } label: {
            Image(systemName: "minus.circle")
          }
          .buttonStyle(.borderless)
          .help("Remove step")
          .disabled(store.busy)
        }
      }
      HStack(spacing: 8) {
        TextField("Add a step", text: $draft)
          .textFieldStyle(.roundedBorder)
          .onSubmit(add)
        Button(action: add) {
          Image(systemName: "plus.circle.fill")
        }
        .buttonStyle(.borderless)
        .help("Add a step")
        .disabled(
          store.busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || steps.count >= 24)
      }
    }
    .onAppear { steps = quest.questSteps }
    .onChange(of: quest.questSteps) { steps = $0 }
    .onChange(of: store.error) { if $0 != nil { steps = quest.questSteps } }
  }
  private func add() {
    let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty, steps.count < 24, !store.busy else { return }
    if title.count > 120 {
      store.error = "Подпункт слишком длинный"
      return
    }
    var next = steps
    next.append(QuestStep(id: UUID().uuidString.lowercased(), title: title, done: false))
    draft = ""
    commit(next)
  }
  private func commit(_ next: [QuestStep]) {
    steps = next
    store.error = nil
    store.replaceQuestSteps(quest, steps: next)
  }
}

private struct CapsuleMenu<Content: View>: View {
  var label: Text
  @ViewBuilder var content: () -> Content
  var body: some View {
    Menu(content: content) {
      HStack(spacing: 7) {
        label.lineLimit(1)
        Image(systemName: "chevron.up.chevron.down")
          .font(.system(size: 9, weight: .semibold))
          .accessibilityHidden(true)
      }
      .font(.system(size: 13))
      .foregroundStyle(Color.accentColor)
      .padding(.leading, 12)
      .padding(.trailing, 10)
      .padding(.vertical, 5)
      .background(Color.primary.opacity(0.045), in: Capsule())
      .overlay { Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1) }
      .contentShape(Capsule())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
  }
}

private struct PlannedSessionInput: View {
  var title: LocalizedStringKey
  @Binding var value: Int
  var minimum: Int
  var maximum: Int
  var body: some View {
    LabeledContent(title) {
      HStack(spacing: 0) {
        Button {
          value = min(maximum, max(minimum, value - 1))
        } label: {
          Image(systemName: "minus").frame(width: 26, height: 26)
        }.disabled(value <= minimum).accessibilityLabel("Fewer sessions")
        TextField(title, value: $value, format: .number.grouping(.never))
          .labelsHidden().textFieldStyle(.plain).multilineTextAlignment(.center)
          .font(.system(size: 13).monospacedDigit()).frame(width: 48)
        Button {
          value = min(maximum, max(minimum, value + 1))
        } label: {
          Image(systemName: "plus").frame(width: 26, height: 26)
        }.disabled(value >= maximum).accessibilityLabel("More sessions")
      }
      .buttonStyle(.borderless).padding(3)
      .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
      .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)) }
    }
  }
}

struct SkillForm: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  var skillID: String? = nil
  @State private var title = ""
  @State private var domain = "Mind"
  @State private var dependency = ""
  @State private var apps: [String] = []
  @State private var sites: [String] = []
  @State private var site = ""
  @State private var listMessage = ""
  private var editing: Skill? { store.state?.skills.first { $0.id == skillID } }
  var body: some View {
    let _ = locale
    SheetShell(
      title: skillID == nil ? "New skill" : "Edit skill",
      actionTitle: skillID == nil ? "Create" : "Save",
      valid: !title.trimmingCharacters(in: .whitespaces).isEmpty, height: 400,
      save: {
        var prerequisites = PrimaryDependency.updating(
          editing?.prerequisites ?? [], selected: dependency)
        if let skillID { prerequisites.removeAll { $0 == skillID } }
        let storedTitle = editing.flatMap { title == $0.displayTitle ? $0.title : nil } ?? title
        var values: [String: Any] = [
          "title": storedTitle, "domain": domain,
          "prerequisites": prerequisites,
          "allowed_apps": apps, "allowed_sites": sites,
        ]
        if let skillID { values["id"] = skillID }
        store.send(skillID == nil ? "create_skill" : "update_skill", values) { store.sheet = nil }
      }
    ) {
      TextField("Title", text: $title)
      Picker("Category", selection: $domain) {
        Text("Learning").tag("Mind")
        Text("Physical fitness").tag("Body")
        Text("Organization").tag("Organization")
        Text("Social").tag("Social")
        Text("Recovery").tag("Recovery")
      }
      Picker("Prerequisite", selection: $dependency) {
        Text("None").tag("")
        ForEach((store.state?.skills ?? []).filter { $0.id != skillID }) {
          Text($0.displayTitle).tag($0.id)
        }
      }
      HStack(spacing: 5) {
        Text("Allowed apps and sites")
        HintButton(
          text: "The timer counts while one of these is the front window. ASCEND itself always counts. A website counts when its tab is active. Leave both empty to count every app."
        )
      }
      ForEach(apps, id: \.self) { bundle in
        focusChip(FocusList.applicationName(bundle)) { apps.removeAll { $0 == bundle } }
      }
      Button("Add application…") {
        guard let chosen = FocusList.chooseApplication() else {
          listMessage = "This application has no bundle identifier."
          return
        }
        listMessage = ""
        if !apps.contains(chosen.bundle) { apps.append(chosen.bundle) }
      }
      .disabled(apps.count >= FocusList.limit)
      ForEach(sites, id: \.self) { host in
        focusChip(host) { sites.removeAll { $0 == host } }
      }
      HStack {
        TextField("Add a website", text: $site)
          .onSubmit { addSite() }
        Button("Add") { addSite() }.disabled(sites.count >= FocusList.limit)
      }
      if !listMessage.isEmpty {
        Text(LocalizedStringKey(listMessage)).font(.system(size: 11)).foregroundStyle(AppStyle.amber)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .onAppear {
      guard let skill = editing else { return }
      title = skill.displayTitle
      domain = skill.domain
      dependency = skill.prerequisites.first ?? ""
      apps = skill.focusApps
      sites = skill.focusSites
    }
  }
  private func addSite() {
    guard sites.count < FocusList.limit else { return }
    guard let host = FocusList.site(site) else {
      listMessage = "Enter a domain such as github.com."
      return
    }
    listMessage = ""
    site = ""
    if !sites.contains(host) { sites.append(host) }
  }
  private func focusChip(_ title: String, remove: @escaping () -> Void) -> some View {
    HStack {
      Text(title).lineLimit(1)
      Spacer()
      Button(action: remove) {
        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
      }
      .buttonStyle(.borderless).accessibilityLabel("Remove")
    }
  }
}

struct TargetForm: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  @State private var skill = ""
  @State private var value = 150.0
  @State private var unit = "Minutes"
  @State private var weight = 1.0
  @State private var next = false
  var body: some View {
    let _ = locale
    SheetShell(
      title: "Weekly goal", valid: !skill.isEmpty && value > 0 && weight > 0 && weight <= 10, height: 280,
      save: {
        store.send(
          "target",
          ["skill_id": skill, "target": value, "weight": weight, "unit": unit, "next_week": next]
        ) { store.sheet = nil }
      }
    ) {
      Picker("Skill", selection: $skill) {
        ForEach(store.state?.skills ?? []) { Text($0.displayTitle).tag($0.id) }
      }
      TextField("Target", value: $value, format: .number)
      Picker("Unit", selection: $unit) {
        Text("Minutes").tag("Minutes")
        Text("Sessions").tag("Sessions")
        Text("Days").tag("Days")
        Text("Milestones").tag("Milestones")
      }
      LabeledContent {
        TextField("Weight", value: $weight, format: .number).labelsHidden()
      } label: {
        HStack(spacing: 5) {
          Text("Weight")
          HintButton(
            text: "Weight is above 0 and at most 10. Sessions and days count after 5 credited minutes."
          )
        }
      }
      Toggle("Next week", isOn: $next)
    }.onAppear { skill = store.state?.skills.first?.id ?? "" }
  }
}

struct FinishForm: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  let id: String
  let quest: String
  let seconds: Int
  let notes: String
  @State private var minutes = 0.0
  @State private var result = ""
  @State private var finish = false
  private var strict: Bool { store.state?.active?.id == id && store.state?.active?.isStrict == true }
  private var manualBlocked: Bool { store.state?.settings.strict_mode == true && !strict }
  private var savedSessions: Int {
    store.state?.sessions.filter { $0.quest_id == quest }.count ?? 0
  }
  private var canCloseQuest: Bool {
    let target = store.state?.quest(quest)?.sessionTarget ?? 1
    return savedSessions + 1 >= target
  }
  var body: some View {
    let _ = locale
    SheetShell(
      title: "Finish session",
      valid: !manualBlocked && minutes > 0 && minutes <= 1440
        && !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, height: strict || manualBlocked ? 330 : 280,
      save: {
        store.send(
          "complete",
          [
            "id": id, "quest_id": quest, "seconds": strict ? (store.state?.active?.elapsed_seconds ?? seconds) : Int((minutes * 60).rounded()), "result": result,
            "finish": finish && (store.state?.quest(quest)?.kind == "Habit" || canCloseQuest),
          ]
        ) { store.sheet = nil }
      }
    ) {
      HStack(spacing: 6) {
        Text(store.state?.quest(quest)?.title ?? L("Session")).font(.headline)
        if manualBlocked {
          HintButton(
            text: "Strict mode records only a camera session. Start the session to save time.")
        }
      }
      if let item = store.state?.quest(quest), item.kind != "Habit" {
        Text(
          L(
            "Saved sessions: %d · planned: %d",
            savedSessions, item.sessionTarget)
        )
        .font(.system(size: 12)).foregroundStyle(.secondary)
      }
      HStack(spacing: 8) {
        TextField(
          "Active time, min", value: $minutes, format: .number.precision(.fractionLength(0...2)))
          .disabled(strict || manualBlocked)
        if strict {
          HintButton(text: "Strict time is counted by presence detection and cannot be edited.")
        }
      }
      TextField("Outcome", text: $result, axis: .vertical).lineLimit(3...5)
      if store.state?.quest(quest)?.kind != "Habit" {
        Toggle(isOn: $finish) {
          HStack(spacing: 5) {
            Text("Quest completed")
            if !canCloseQuest {
              HintButton(text: "The quest closes on the last planned session.")
            }
          }
        }.disabled(!canCloseQuest)
      }
    }.onAppear {
      minutes = Double(seconds) / 60
      result = notes
      finish = store.state?.quest(quest)?.kind == "Habit"
    }
  }
}

struct PlanForm: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  @State private var selected = Set<String>()
  var body: some View {
    let _ = locale
    SheetShell(
      title: "Today's plan", actionTitle: "Accept plan",
      valid: !selected.isEmpty && selected.count <= 3, height: 340,
      save: {
        store.send("plan", ["ids": Array(selected)]) { store.sheet = nil }
      }
    ) {
      ForEach(
        (store.state?.quests ?? []).filter { quest in
          store.available(quest)
            && !(store.state?.sessions.contains {
              $0.quest_id == quest.id && $0.day == store.summary?.today
            } ?? false)
        }
      ) { quest in
        Toggle(
          isOn: Binding(
            get: { selected.contains(quest.id) },
            set: { on in if on { selected.insert(quest.id) } else { selected.remove(quest.id) } })
        ) {
          HStack {
            Text(quest.title)
            Spacer()
            Text(L("%d min", quest.estimate_minutes)).foregroundStyle(.secondary)
          }
        }.disabled(!selected.contains(quest.id) && selected.count >= 3)
      }
    }.onAppear { selected = Set(store.summary?.proposed ?? []) }
  }
}

struct ExcuseForm: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  let id: String?
  @State private var reason = ""
  var body: some View {
    let _ = locale
    SheetShell(
      title: id == nil ? "Rest day" : "Reschedule",
      valid: !reason.trimmingCharacters(in: .whitespaces).isEmpty, height: 150,
      save: {
        store.send("excuse", ["id": id as Any? ?? NSNull(), "reason": reason]) { store.sheet = nil }
      }
    ) { TextField("Reason", text: $reason, axis: .vertical).lineLimit(2...4) }
  }
}

struct CheckInForm: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  @State private var energy = 65.0
  @State private var fatigue = 30.0
  @State private var focus = 70.0
  @State private var minutes = 90
  @State private var unwell = false
  var body: some View {
    let _ = locale
    SheetShell(
      title: "Check-in", height: 300,
      save: {
        store.send(
          "checkin",
          [
            "energy": Int(energy), "fatigue": Int(fatigue), "focus": Int(focus), "minutes": minutes,
            "unwell": unwell,
          ]
        ) { store.sheet = nil }
      }
    ) {
      scale("Energy", value: $energy)
      scale("Fatigue", value: $fatigue)
      scale("Focus", value: $focus)
      TextField("Available time, min", value: $minutes, format: .number)
      Toggle("Feeling unwell", isOn: $unwell)
    }.onAppear {
      if let c = store.state?.checkins.first(where: { $0.day == store.summary?.today }) {
        energy = Double(c.energy)
        fatigue = Double(c.fatigue)
        focus = Double(c.focus)
        minutes = c.available_minutes
        unwell = c.unwell
      } else {
        minutes = store.state?.settings.daily_minutes ?? 90
      }
    }
  }
  private func scale(_ label: String, value: Binding<Double>) -> some View {
    HStack {
      Slider(value: value, in: 0...100, step: 1) { Text(L(label)) }
      Text("\(Int(value.wrappedValue))").monospacedDigit().foregroundStyle(.secondary).frame(
        width: 30)
    }
  }
}

struct TextEntryForm: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  let title: String
  let label: String
  let command: String
  let id: String?
  @State private var text = ""
  var body: some View {
    let _ = locale
    SheetShell(
      title: title,
      valid: text.trimmingCharacters(in: .whitespacesAndNewlines).count
        >= (command == "verify" ? 8 : 1)
        && (command != "verify"
          || (id.flatMap { id in
            store.summary.map { store.state?.canVerifySkill(id, summary: $0) == true }
          } ?? false)),
      height: 260,
      save: {
        var values: [String: Any] = command == "verify" ? ["evidence": text] : ["text": text]
        if let id { values["id"] = id }
        store.send(command, values) { store.sheet = nil }
      }
    ) {
      if let id { Text(store.state?.skill(id) ?? "").font(.headline) }
      if command == "verify", let id, store.state?.skillQuestsCompleted(id) == false {
        HintButton(text: "Complete all quests to verify this skill.")
      }
      TextEditor(text: $text).font(.body).frame(minHeight: 180).accessibilityLabel(L(label))
    }
  }
}
