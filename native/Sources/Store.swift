import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class Store: ObservableObject {
  let presence = PresenceMonitor()
  let focusReporter = FocusReporter()
  @Published var state: GameState?
  @Published private(set) var profileGeneration = 0
  @Published var summary: Summary?
  @Published var page: Page? = .dashboard
  @Published var questTreeSkill: String?
  var questDraftSkill: String?
  var questDraftPrerequisite: String?
  @Published var settingsFrom: Page = .character
  @Published var settingsTab: SettingsTab = .general
  @Published var sheet: Sheet?
  @Published var error: String?
  @Published var preview: ImportPreview?
  @Published var focusMode = false
  @Published var skillEditing = false
  @Published var skillSelection: Set<String> = []
  @Published var confirmSkillDelete = false
  @Published var busy = false
  private var tickPending = false
  private var lastRefresh = Date()
  private var engine: EngineProcess?
  private var timer: Timer?
  private var monitor: Any?
  private struct Operation {
    var command: String
    var values: [String: Any]
    var then: (() -> Void)?
  }
  private var pending: [Operation] = []
  private var inFlight: Operation?
  private var stopped = false
  private var terminating = false
  init(engine suppliedEngine: EngineProcess? = nil, startMonitoring: Bool = true) {
    presence.onPresence = { [weak self] id, present, time in
      self?.send("presence", ["id": id, "present": present, "observed_at_ms": time])
    }
    focusReporter.onReport = { [weak self] bundle, host in
      self?.sendFocus(bundle, host)
    }
    focusReporter.onActivate = { [weak self] in self?.reportFocus() }
    if let suppliedEngine {
      engine = suppliedEngine
      send("load")
    } else {
      // Launch Services may construct scene state before the AppKit run loop is ready.
      // Defer subprocess setup and errors until the observable store is installed in the window.
      DispatchQueue.main.async { [weak self] in self?.launchEngine() }
    }
    guard startMonitoring else { return }
    focusReporter.start()
    let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
    RunLoop.main.add(timer, forMode: .common)
    self.timer = timer
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let handled = MainActor.assumeIsolated { self?.handleShortcut(event) == true }
      return handled ? nil : event
    }
  }
  private func launchEngine() {
    guard !stopped, engine == nil else { return }
    do {
      engine = try EngineProcess()
      send("load")
    } catch { self.error = error.localizedDescription }
  }
  func send(_ command: String, _ values: [String: Any] = [:], then: (() -> Void)? = nil) {
    guard !stopped, engine != nil else { return }
    var values = values
    if command == "notes", values["id"] == nil, let activeID = state?.active?.id {
      values["id"] = activeID
    }
    let operation = Operation(command: command, values: values, then: then)
    // Preserve ordering across user actions, but never retain every intermediate keystroke.
    if command == "presence", let index = pending.lastIndex(where: { $0.command == "presence" }) {
      pending[index] = operation
    } else if command == "focus", let index = pending.lastIndex(where: { $0.command == "focus" }) {
      pending[index] = operation
    } else if command == "notes", pending.last?.command == "notes", pending.last?.then == nil, then == nil,
      pending.last?.values["id"] as? String == values["id"] as? String
    {
      pending[pending.count - 1] = operation
    } else {
      guard pending.count < 256 else {
        if command == "tick" { tickPending = false }
        error = L("The local engine is busy. Wait for the current action to finish.")
        return
      }
      pending.append(operation)
    }
    refreshBusy()
    runNext()
  }
  private func refreshBusy() {
    let quiet = ["tick", "notes", "cancel_import", "presence", "focus"]
    busy =
      inFlight.map { !quiet.contains($0.command) } == true
      || pending.contains { !quiet.contains($0.command) }
  }
  private func runNext() {
    guard !stopped, inFlight == nil, !pending.isEmpty, let engine else { return }
    let operation = pending.removeFirst()
    inFlight = operation
    var payload = operation.values
    payload["command"] = operation.command
    if ["tick", "notes"].contains(operation.command) { payload["compact"] = true }
    engine.send(payload) { [weak self] result in
      guard let self, !self.stopped else { return }
      // Release the completed callback before invoking it or dispatching more work.
      self.inFlight = nil
      if operation.command == "tick" { self.tickPending = false }
      self.refreshBusy()
      switch result {
      case .failure(let error):
        self.presence.end()
        self.pending.removeAll()
        self.tickPending = false
        self.refreshBusy()
        self.error = error.localizedDescription
      case .success(let response):
        if response.ok {
          if let state = response.state { self.state = state }
          if operation.command == "confirm_import" { self.profileGeneration += 1 }
          if let summary = response.summary { self.summary = summary }
          if let timer = response.timer, self.state?.active != timer.active {
            self.state?.active = timer.active
          }
          if !self.terminating { self.presence.sync(active: self.state?.active) }
          if operation.command == "start" { self.reportFocus() }
          if let preview = response.extra?.preview { self.preview = preview }
          operation.then?()
        } else {
          if operation.command == "presence" { self.presence.end() }
          if operation.command == "start" {
            self.presence.end()
            if case .startSession = self.sheet { self.presence.beginPreparation() }
          }
          self.error = response.error ?? "Не удалось сохранить изменения"
          if operation.command == "routine_check" { self.send("load") }
        }
      }
      self.runNext()
    }
  }
  private func tick() {
    guard state != nil, !tickPending, error == nil else { return }
    guard state?.active?.running == true || Date().timeIntervalSince(lastRefresh) >= 30 else {
      return
    }
    lastRefresh = Date()
    tickPending = true
    if state?.active?.running == true { reportFocus() }
    send("tick")
  }
  private func reportFocus() {
    guard let active = state?.active, active.running,
      let quest = state?.quest(active.quest_id),
      let skill = state?.skills.first(where: { $0.id == quest.skill_id }),
      skill.restrictsFocus
    else { return }
    focusReporter.sample(readSite: !skill.focusSites.isEmpty)
  }
  private func sendFocus(_ bundle: String, _ host: String?) {
    var values: [String: Any] = ["bundle_id": bundle]
    if let host { values["host"] = host }
    send("focus", values)
  }
  func prepareToTerminate(_ completion: @escaping () -> Void) {
    terminating = true
    timer?.invalidate()
    // Save the latest coalesced draft before EOF; never keep termination waiting indefinitely.
    let notes = pending.last { $0.command == "notes" }
    presence.end()
    pending.removeAll()
    if let active = state?.active, active.isStrict {
      send("presence", ["id": active.id, "present": false, "observed_at_ms": UInt64(max(0, Date().timeIntervalSince1970 * 1000))])
    }
    var finished = false
    let finish = { [weak self] in
      guard !finished else { return }
      finished = true
      self?.shutdown()
      completion()
    }
    if let notes {
      send("notes", notes.values, then: finish)
    } else if inFlight != nil {
      send("tick", then: finish)
    } else {
      finish()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { finish() }
  }
  func shutdown() {
    guard !stopped else { return }
    stopped = true
    presence.end()
    presence.onPresence = nil
    focusReporter.onReport = nil
    focusReporter.onActivate = nil
    focusReporter.stop()
    timer?.invalidate()
    timer = nil
    if let monitor { NSEvent.removeMonitor(monitor) }
    monitor = nil
    pending.removeAll()
    inFlight = nil
    tickPending = false
    busy = false
    engine?.shutdown()
  }
  deinit {
    timer?.invalidate()
    if let monitor { NSEvent.removeMonitor(monitor) }
    engine?.shutdown()
  }
  func startSession(_ id: String) {
    guard canStart, !busy, let quest = state?.quest(id), available(quest) else { return }
    if strictLogging {
      sheet = .startSession(id)
    } else {
      send("start", ["id": id, "strict": false])
    }
  }
  func confirmSessionStart(_ id: String, useCamera: Bool) {
    guard canStart, !busy, let quest = state?.quest(id), available(quest) else { return }
    if useCamera {
      guard presence.commitPreparation() else { return }
    } else { presence.end() }
    send("start", ["id": id, "strict": useCamera]) { [weak self] in self?.sheet = nil }
  }
  func cancelImport() {
    preview = nil
    // AppKit may dismiss the confirmation before invoking its Replace action.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.preview == nil else { return }
      let importing = ["confirm_import", "preview_import"]
      guard !importing.contains(self.inFlight?.command ?? ""),
        !self.pending.contains(where: { importing.contains($0.command) })
      else { return }
      self.send("cancel_import")
    }
  }
  func navigate(_ page: Page) {
    self.page = page
    if page != .skillTree && page != .settings { questTreeSkill = nil }
    focusMode = false
    if page != .skills { endSkillEditing() }
  }
  func openQuestTree(_ skillID: String) {
    endSkillEditing()
    questTreeSkill = skillID
    page = .skillTree
    focusMode = false
  }
  func newQuest(skillID: String? = nil, prerequisiteID: String? = nil) {
    questDraftSkill = skillID ?? (page == .skillTree ? questTreeSkill : nil)
    questDraftPrerequisite = prerequisiteID
    sheet = .quest
  }
  func saveQuest(
    id: String? = nil, title: String, outcome: String, skillID: String, kind: String,
    priority: Int, minutes: Int, sessions: Int, difficulty: Double, bonus: Int,
    deadline: String?, dependencies: [String], steps: [[String: Any]], then: (() -> Void)? = nil
  ) {
    var values: [String: Any] = [
      "title": title, "outcome": outcome, "skill_id": skillID, "kind": kind, "priority": priority,
      "minutes": minutes, "planned_sessions": sessions, "difficulty": difficulty,
      "bonus": kind == "Project" ? bonus : 0,
      "deadline": deadline.map { $0 as Any } ?? NSNull(),
      "dependencies": dependencies, "steps": steps,
    ]
    if let id { values["id"] = id }
    send(id == nil ? "create_quest" : "update_quest", values, then: then)
  }
  func replaceQuestSteps(_ quest: Quest, steps: [QuestStep]) {
    saveQuest(
      id: quest.id, title: quest.title, outcome: quest.outcome, skillID: quest.skill_id,
      kind: quest.kind, priority: quest.priority, minutes: quest.estimate_minutes,
      sessions: quest.sessionTarget, difficulty: quest.difficulty,
      bonus: Int(quest.bonus_milli / 1000), deadline: quest.deadline,
      dependencies: quest.dependencies,
      steps: steps.map { ["id": $0.id, "title": $0.title, "done": $0.done] }
    )
  }
  func openSettings() {
    if page != .settings { settingsFrom = page ?? .character }
    page = .settings
  }
  func closeSettings() {
    page = settingsFrom == .settings ? .character : settingsFrom
  }
  func endSkillEditing() {
    skillEditing = false
    skillSelection = []
    confirmSkillDelete = false
  }
  func deleteSelectedSkills() {
    let ids = Array(skillSelection)
    guard !ids.isEmpty else { return }
    deleteSkills(ids[...])
  }
  private func deleteSkills(_ remaining: ArraySlice<String>) {
    guard let id = remaining.first else {
      endSkillEditing()
      return
    }
    send("delete_skill", ["id": id]) { [weak self] in
      self?.deleteSkills(remaining.dropFirst())
    }
  }
  func finish(_ quest: Quest? = nil) {
    if let active = state?.active {
      let show = { [weak self] in
        guard let self, let current = self.state?.active, current.id == active.id else { return }
        self.sheet = .finish(
          current.id, current.quest_id, current.elapsed_seconds, current.notes)
      }
      if active.running { send("pause", then: show) } else { show() }
    } else if let quest {
      sheet = .finish(UUID().uuidString.lowercased(), quest.id, quest.estimate_minutes * 60, "")
    }
  }
  func export(csv: Bool) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [csv ? .commaSeparatedText : .json]
    panel.nameFieldStringValue = csv ? "ASCEND.csv" : "ASCEND.json"
    if panel.runModal() == .OK, let url = panel.url {
      send("export", ["path": url.path, "csv": csv])
    }
  }
  func importFile() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json, .commaSeparatedText]
    panel.allowsMultipleSelection = false
    if panel.runModal() == .OK, let url = panel.url { send("preview_import", ["path": url.path]) }
  }
  var canStart: Bool { state?.active == nil }
  var strictLogging: Bool { state?.settings.strict_mode == true }
  func available(_ quest: Quest) -> Bool {
    guard let state, let summary else { return false }
    return !quest.closed && summary.unlocked_quests.contains(quest.id)
      && !(quest.kind == "Habit"
        && state.sessions.contains { $0.quest_id == quest.id && $0.day == summary.today })
  }
  private func handleShortcut(_ event: NSEvent) -> Bool {
    guard UserDefaults.standard.object(forKey: "shortcutsEnabled") as? Bool ?? true,
      event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
    else { return false }
    switch event.keyCode {
    case 18: navigate(.dashboard)
    case 19: navigate(.skills)
    case 20: navigate(.quests)
    case 21: navigate(.balance)
    case 45: newQuest()
    case 38: navigate(.journal)
    case 3: focusMode.toggle()
    case 1: if sheet != nil { NotificationCenter.default.post(name: .ascendSave, object: nil) }
    case 36: if state?.active != nil { send("pause") }
    default: return false
    }
    return true
  }
}
