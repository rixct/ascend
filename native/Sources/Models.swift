import Foundation

struct GameState: Decodable {
  var settings: Profile
  var character_xp_milli: UInt64
  var skills: [Skill]
  var quests: [Quest]
  var sessions: [Session]
  var plans: [DailyPlan]
  var targets: [WeeklyTarget]
  var checkins: [CheckIn]
  var journal: [JournalEntry]
  var events: [GameEvent]
  var active: ActiveSession?
  var routine_versions: [RoutineVersion]?
  var routine_days: [RoutineDay]?
  var fulfilledQuestIDs: Set<String> {
    var days: [String: Set<String>] = [:]
    for session in sessions where session.completed_quest {
      days[session.quest_id, default: []].insert(session.day)
    }
    return Set(quests.compactMap { quest in
      quest.status == "Completed"
        || (quest.kind == "Habit" && (days[quest.id]?.count ?? 0) >= max(quest.sessionTarget, 7))
        ? quest.id : nil
    })
  }
  func habitDays(_ id: String) -> Int {
    Set(sessions.filter { $0.quest_id == id && $0.completed_quest }.map(\.day)).count
  }
  func questFulfilled(_ quest: Quest) -> Bool {
    if quest.status == "Completed" { return true }
    return quest.kind == "Habit" && habitDays(quest.id) >= max(quest.sessionTarget, 7)
  }
  func skillQuestsCompleted(_ id: String) -> Bool {
    quests
      .filter { $0.skill_id == id && $0.status != "Cancelled" && $0.status != "Missed" }
      .allSatisfy { questFulfilled($0) }
  }
  func verificationCap(_ id: String) -> Int {
    let open = quests.filter {
      $0.skill_id == id && $0.status != "Cancelled" && $0.status != "Missed"
    }
    return max(1, open.filter { questFulfilled($0) }.count)
  }
  func canVerifySkill(_ id: String, summary: Summary) -> Bool {
    guard summary.unlocked_skills.contains(id), skillQuestsCompleted(id),
      let skill = skills.first(where: { $0.id == id })
    else { return false }
    return skill.mastery < verificationCap(id)
  }
  func skill(_ id: String) -> String { skills.first { $0.id == id }?.displayTitle ?? "" }
  func quest(_ id: String) -> Quest? { quests.first { $0.id == id } }
}
struct RoutineItem: Decodable, Identifiable {
  var id: String
  var title: String
}
struct RoutineVersion: Decodable {
  var effective_from: String
  var enabled: Bool
  var items: [RoutineItem]
}
struct RoutineDay: Decodable {
  var day: String
  var completed: [String]
}
struct RoutineChecklistItem: Decodable, Identifiable {
  var id: String
  var title: String
  var completed: Bool
}
struct DailyRoutine: Decodable {
  var day: String
  var items: [RoutineChecklistItem]
}
struct RoutineDraftItem: Identifiable {
  let id = UUID()
  var title = ""
}
enum RoutineDraft {
  static let maxItems = 12
  static var blank: [RoutineDraftItem] { (0..<3).map { _ in RoutineDraftItem() } }
  static func titles(_ rows: [RoutineDraftItem]) -> [String] {
    rows.map { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
  }
  static func valid(_ rows: [RoutineDraftItem]) -> Bool {
    let names = titles(rows)
    return rows.count <= maxItems && !names.isEmpty && names.count <= maxItems
      && names.allSatisfy { $0.unicodeScalars.count <= 100 }
      && Set(names.map { $0.lowercased() }).count == names.count
  }
}
struct Profile: Decodable {
  var name: String
  var avatar: String?
  var bio: String?
  var dark: Bool
  var growth_percent: Int
  var daily_minutes: Int
  var onboarded: Bool
  var strict_mode: Bool? = nil
}
struct Skill: Decodable, Identifiable, Equatable {
  var id: String
  var title: String
  var domain: String
  var xp_milli: UInt64
  var mastery: Int
  var evidence: [String]
  var prerequisites: [String]
  var allowed_apps: [String]? = nil
  var allowed_sites: [String]? = nil
  var focusApps: [String] { allowed_apps ?? [] }
  var focusSites: [String] { allowed_sites ?? [] }
  var restrictsFocus: Bool { !focusApps.isEmpty || !focusSites.isEmpty }
}
struct QuestStep: Decodable, Identifiable, Equatable {
  var id: String
  var title: String
  var done: Bool
}
struct Quest: Decodable, Identifiable {
  var id: String
  var title: String
  var outcome: String
  var skill_id: String
  var kind: String
  var priority: Int
  var estimate_minutes: Int
  var planned_sessions: Int?
  var sessionTarget: Int { planned_sessions ?? 1 }
  var difficulty: Double
  var bonus_milli: UInt64
  var deadline: String?
  var dependencies: [String]
  var steps: [QuestStep]? = nil
  var questSteps: [QuestStep] { steps ?? [] }
  var status: String
  var closed: Bool { ["Completed", "Cancelled", "Missed"].contains(status) }
  var statusName: String {
    [
      "Planned": "Planned", "Active": "In progress", "Paused": "Paused",
      "Completed": "Completed", "Cancelled": "Cancelled", "Missed": "Missed",
    ][status].map { L($0) } ?? status
  }
  var kindName: String {
    L(["Daily": "Until it's done", "Project": "One step", "Habit": "Every day"][kind] ?? kind)
  }
}
struct Session: Decodable, Identifiable {
  var id: String
  var quest_id: String
  var skill_id: String
  var day: String
  var seconds: Int
  var reward_milli: UInt64
  var explanation: String
  var result: String
  var completed_quest: Bool
  var strict: Bool?
}
struct QuestPractice {
  var sessions = 0
  var seconds = 0
  static func totals(_ sessions: [Session]) -> [String: QuestPractice] {
    var totals: [String: QuestPractice] = [:]
    for session in sessions {
      totals[session.quest_id, default: QuestPractice()].sessions += 1
      totals[session.quest_id, default: QuestPractice()].seconds += session.seconds
    }
    return totals
  }
}
struct ActiveSession: Decodable, Equatable {
  var id: String
  var quest_id: String
  var elapsed_seconds: Int
  var running: Bool
  var strict: Bool?
  var presence_confirmed: Bool?
  var focus_confirmed: Bool? = nil
  var isStrict: Bool { strict == true }
  var isCounting: Bool {
    running && (!isStrict || presence_confirmed == true) && focus_confirmed != false
  }
  var statusTitle: String {
    if !running { return "Paused" }
    if focus_confirmed == false { return "Waiting" }
    if !isCounting { return "Paused" }
    return "In progress"
  }
  var notes: String
}
struct PlanItem: Decodable, Identifiable {
  var quest_id: String
  var completed: Bool
  var excused: Bool
  var estimate_minutes: Int
  var id: String { quest_id }
}
struct DailyPlan: Decodable {
  var day: String
  var items: [PlanItem]
  var rest: Bool
  var reason: String
}
struct WeeklyTarget: Decodable, Identifiable {
  var id: String
  var week: String
  var skill_id: String
  var target: Double
  var weight: Double
  var unit: String
  var unitName: String {
    L(
      ["Minutes": "min", "Sessions": "sessions", "Days": "days", "Milestones": "milestones"][unit]
        ?? unit)
  }
}
struct CheckIn: Decodable {
  var day: String
  var energy: Int
  var fatigue: Int
  var focus: Int
  var available_minutes: Int
  var unwell: Bool
}
struct JournalEntry: Decodable, Identifiable {
  var id: String
  var day: String
  var text: String
}
struct GameEvent: Decodable, Identifiable {
  var id: String
  var at: String
  var kind: String
  var description: String
}
struct Attribute: Decodable, Identifiable {
  var name: String
  var value: Double
  var id: String { name }
}
struct HistoryDay: Decodable, Identifiable {
  var day: String
  var minutes: Double
  var xp: Double
  var fatigue: Double?
  var discipline: Double?
  var id: String { day }
}
struct TargetActual: Decodable {
  var id: String
  var actual: Double
}
struct Summary: Decodable {
  var routine_today: DailyRoutine?
  var routine_score: Double?
  var today: String
  var week: String
  var level: Int
  var level_xp: Double
  var next_xp: Double
  var discipline: Double?
  var preliminary: Bool
  var balance: Double?
  var suggested_minutes: Int
  var recommendation: String
  var recommendation_detail: String
  var proposed: [String]
  var unlocked_skills: [String]
  var unlocked_quests: [String]
  var attributes: [Attribute]
  var history: [HistoryDay]
  var targets: [TargetActual]
  var directory: String
  func actual(_ id: String) -> Double { targets.first { $0.id == id }?.actual ?? 0 }
}
struct ImportPreview: Decodable {
  var name: String
  var skills: Int
  var quests: Int
  var sessions: Int
}
struct Extra: Decodable {
  var file: String?
  var preview: ImportPreview?
}
struct TimerSnapshot: Decodable {
  var active: ActiveSession?
}
struct Response: Decodable {
  var timer: TimerSnapshot?
  var ok: Bool
  var error: String?
  var state: GameState?
  var summary: Summary?
  var extra: Extra?
}

enum Page: String, CaseIterable, Identifiable {
  case dashboard = "Today"
  case character = "Character"
  case skills = "Skills"
  case skillTree = "Skill tree"
  case quests = "Quests"
  case balance = "Balance"
  case analytics = "Analytics"
  case journal = "Journal"
  case settings = "Settings"
  var id: Self { self }
  /// Sidebar entries. Character sits in the profile row; Settings opens from that page.
  static var menu: [Page] {
    allCases.filter { $0 != .character && $0 != .settings && $0 != .skillTree }
  }
  var symbol: String {
    switch self {
    case .dashboard: "sun.max"
    case .character: "person.crop.circle"
    case .skills: "point.3.connected.trianglepath.dotted"
    case .skillTree: "point.3.filled.connected.trianglepath.dotted"
    case .quests: "checklist"
    case .balance: "scale.3d"
    case .analytics: "chart.bar"
    case .journal: "book.closed"
    case .settings: "gearshape"
    }
  }
}
enum SettingsTab: String, CaseIterable, Identifiable {
  case general = "General"
  case notifications = "Notifications"
  case shortcuts = "Shortcuts"
  case data = "Data"
  case rules = "Rules"
  var id: Self { self }
  var symbol: String {
    switch self {
    case .general: "gearshape"
    case .notifications: "bell"
    case .shortcuts: "keyboard"
    case .data: "externaldrive"
    case .rules: "function"
    }
  }
}
enum Sheet: Identifiable {
  case quest, skill, target
  case editSkill(String)
  case editQuest(String)
  case startSession(String)
  case mastery(String)
  case finish(String, String, Int, String)
  case plan
  case excuse(String?)
  case checkin, journal, milestones
  var id: String {
    switch self {
    case .quest: "quest"
    case .editQuest(let id): "edit-quest-" + id
    case .startSession(let id): "start-session-" + id
    case .skill: "skill"
    case .editSkill(let id): "edit-skill-" + id
    case .target: "target"
    case .mastery: "mastery"
    case .finish: "finish"
    case .plan: "plan"
    case .excuse: "excuse"
    case .checkin: "checkin"
    case .journal: "journal"
    case .milestones: "milestones"
    }
  }
}
func clock(_ seconds: Int) -> String { String(format: "%02d:%02d", seconds / 60, seconds % 60) }
func number(_ value: Double) -> String {
  value.formatted(.number.locale(AppLanguage.current.locale).precision(.fractionLength(0...1)))
}
private let dateTextLock = NSLock()
private let dateTextParser: DateFormatter = {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.calendar = Calendar(identifier: .gregorian)
  formatter.dateFormat = "yyyy-MM-dd"
  return formatter
}()
private let dateTextFormatters: [AppLanguage: DateFormatter] = Dictionary(
  uniqueKeysWithValues: AppLanguage.allCases.map { language in
    let formatter = DateFormatter()
    formatter.locale = language.locale
    formatter.dateStyle = .medium
    return (language, formatter)
  })
func dateText(_ text: String) -> String {
  dateTextLock.lock()
  defer { dateTextLock.unlock() }
  guard let date = dateTextParser.date(from: String(text.prefix(10))) else { return text }
  return dateTextFormatters[AppLanguage.current]?.string(from: date) ?? text
}

/// The forms edit the first dependency; retain the other edges loaded from a graph or import.
enum PrimaryDependency {
  static func updating(_ existing: [String], selected: String) -> [String] {
    guard !selected.isEmpty else { return Array(existing.dropFirst()) }
    if existing.contains(selected) { return [selected] + existing.filter { $0 != selected } }
    return [selected] + existing.dropFirst()
  }
}
