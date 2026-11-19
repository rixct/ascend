import Foundation

struct NotificationPreferences: Codable, Equatable {
  var enabled = false
  var focus = true
  var dailyPlan = true
  var planTime = 9 * 60
  var dailyReview = false
  var reviewTime = 20 * 60 + 30
  var deadlines = true
  var deadlineTime = 18 * 60
  var sound = true
  var quietHours = true
  var quietStart = 22 * 60
  var quietEnd = 8 * 60

  func isQuiet(_ date: Date, calendar: Calendar) -> Bool {
    guard quietHours, quietStart != quietEnd else { return false }
    let minute =
      calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
    return quietStart < quietEnd
      ? minute >= quietStart && minute < quietEnd
      : minute >= quietStart || minute < quietEnd
  }
  var normalized: Self {
    var value = self
    value.planTime = min(1439, max(0, planTime))
    value.reviewTime = min(1439, max(0, reviewTime))
    value.deadlineTime = min(1439, max(0, deadlineTime))
    value.quietStart = min(1439, max(0, quietStart))
    value.quietEnd = min(1439, max(0, quietEnd))
    return value
  }
}

enum NotificationKind: String, Codable {
  case focus, plan, review, deadline, test
}

struct NotificationSnapshot: Codable {
  struct Focus: Codable {
    var id: String
    var title: String
    var running: Bool
    var goalSeconds: Int
    var elapsedSeconds: Int
    var schedulingKey: String { "\(id):\(running):\(goalSeconds):\(title.prefix(100))" }
  }
  struct DueQuest: Codable, Equatable {
    var day: String
    var title: String
  }
  var ready = false
  var planDays: Set<String> = []
  var journalDays: Set<String> = []
  var quests: [DueQuest] = []
  var focus: Focus?

  // Elapsed seconds and session notes must not rebuild OS notifications on every tick.
  var schedulingKey: String {
    let questsKey = quests.map { "\($0.day):\($0.title)" }.joined(separator: "\u{1e}")
    return
      "\(ready)|\(planDays.sorted())|\(journalDays.sorted())|\(questsKey)|\(focus?.schedulingKey ?? "")"
  }
}

struct PlannedNotification: Codable, Equatable {
  var id: String
  var kind: NotificationKind
  var title: String
  var body: String
  var date: Date
  var sound: Bool
  var sessionID: String? = nil
}

enum NotificationPlan {
  static let prefix = "ascend.reminder."
  static func calendar(timeZone: TimeZone = .current) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
  }
  static func dayKey(_ date: Date, calendar: Calendar) -> String {
    let c = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
  }
  static func make(
    preferences: NotificationPreferences, snapshot: NotificationSnapshot,
    now: Date = Date(), calendar: Calendar = calendar()
  ) -> [PlannedNotification] {
    let p = preferences.normalized
    guard p.enabled, snapshot.ready else { return [] }
    var output: [PlannedNotification] = []
    if p.focus, let focus = snapshot.focus, focus.running {
      let remaining = focus.goalSeconds - focus.elapsedSeconds
      let date = now.addingTimeInterval(TimeInterval(remaining))
      if remaining > 0, !p.isQuiet(date, calendar: calendar) {
        output.append(
          PlannedNotification(
            id: prefix + "focus." + focus.id, kind: .focus,
            title: L("Your focus time is complete"),
            body: L(
              "%@ — take a break or continue when you're ready.", String(focus.title.prefix(100))),
            date: date, sound: p.sound, sessionID: focus.id))
      }
    }
    for offset in 0..<7 {
      guard
        let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))
      else { continue }
      let key = dayKey(day, calendar: calendar)
      func add(_ kind: NotificationKind, minute: Int, title: String, body: String) {
        guard
          let date = calendar.date(
            bySettingHour: minute / 60, minute: minute % 60, second: 0,
            of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first),
          calendar.isDate(date, inSameDayAs: day), date > now,
          !p.isQuiet(date, calendar: calendar)
        else { return }
        output.append(
          PlannedNotification(
            id: prefix + kind.rawValue + "." + key,
            kind: kind, title: title, body: body, date: date, sound: p.sound))
      }
      if p.dailyPlan, !snapshot.planDays.contains(key), !(offset == 0 && snapshot.focus != nil) {
        add(
          .plan, minute: p.planTime, title: L("A little direction for today"),
          body: L("Choose up to three quests, or make room for a rest day."))
      }
      if p.dailyReview, !snapshot.journalDays.contains(key) {
        add(
          .review, minute: p.reviewTime, title: L("A moment to reflect"),
          body: L("Capture a win, a lesson, or an idea for tomorrow."))
      }
      let due = snapshot.quests.filter { $0.day == key }
      if p.deadlines, !due.isEmpty {
        let titles = due.prefix(3).map { String($0.title.prefix(70)) }.joined(separator: " · ")
        add(
          .deadline, minute: p.deadlineTime, title: L("Quests due today: %d", due.count),
          body: titles)
      }
    }
    return output.sorted { $0.date < $1.date }
  }
}
