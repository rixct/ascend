import Foundation

@main struct NotificationPlanTests {
  static func main() throws {
    let iso = ISO8601DateFormatter()
    let now = iso.date(from: "2026-11-14T08:00:00Z")!
    let calendar = NotificationPlan.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)
    let today = NotificationPlan.dayKey(now, calendar: calendar)
    var preferences = NotificationPreferences()
    var snapshot = NotificationSnapshot(ready: true)
    precondition(
      NotificationPlan.make(
        preferences: preferences, snapshot: snapshot, now: now, calendar: calendar
      ).isEmpty)
    preferences.enabled = true
    preferences.quietHours = false
    preferences.dailyReview = true
    snapshot.quests = [.init(day: today, title: "First"), .init(day: today, title: "Second")]
    var plan = NotificationPlan.make(
      preferences: preferences, snapshot: snapshot, now: now, calendar: calendar)
    precondition(plan.filter { $0.kind == .plan }.count == 7)
    precondition(plan.filter { $0.kind == .review }.count == 7)
    precondition(plan.filter { $0.kind == .deadline }.count == 1)
    precondition(plan.first { $0.kind == .deadline }!.body == "First · Second")
    precondition(Set(plan.map(\.id)).count == plan.count)
    precondition(plan.allSatisfy { $0.date > now })
    snapshot.planDays.insert(today)  // Includes an accepted rest day.
    snapshot.journalDays.insert(today)
    snapshot.quests = []
    plan = NotificationPlan.make(
      preferences: preferences, snapshot: snapshot, now: now, calendar: calendar)
    precondition(plan.filter { $0.kind == .plan }.count == 6)
    precondition(plan.filter { $0.kind == .review }.count == 6)
    precondition(!plan.contains { $0.kind == .deadline })

    snapshot.planDays = []
    snapshot.journalDays = []
    snapshot.focus = .init(
      id: "session", title: "Practice", running: true, goalSeconds: 600, elapsedSeconds: 120)
    plan = NotificationPlan.make(
      preferences: preferences, snapshot: snapshot, now: now, calendar: calendar)
    let focus = plan.first { $0.kind == .focus }!
    precondition(focus.date == now.addingTimeInterval(480))
    precondition(focus.sessionID == "session")
    precondition(!plan.contains { $0.id == NotificationPlan.prefix + "plan." + today })
    let senderRequest = NotificationSenderRequest(
      command: .reconcile, preferences: preferences, snapshot: snapshot, plan: plan)
    let senderData = try JSONEncoder().encode(senderRequest)
    let decodedRequest = try JSONDecoder().decode(NotificationSenderRequest.self, from: senderData)
    precondition(decodedRequest.command == .reconcile && decodedRequest.plan == plan)
    precondition(decodedRequest.snapshot?.focus?.id == focus.sessionID)
    precondition(decodedRequest.preferences == preferences)
    precondition(NotificationRoute.kind(for: NotificationRoute.url(for: .test)!) == .test)
    precondition(NotificationRoute.kind(for: URL(string: "ascend-notification://open/other")!) == nil)
    let key = snapshot.schedulingKey
    snapshot.focus!.elapsedSeconds += 1
    precondition(snapshot.schedulingKey == key, "A clock tick must not rebuild OS schedules")
    snapshot.focus!.running = false
    precondition(snapshot.schedulingKey != key)
    precondition(
      !NotificationPlan.make(
        preferences: preferences, snapshot: snapshot, now: now, calendar: calendar
      ).contains { $0.kind == .focus })
    snapshot.focus!.running = true
    snapshot.focus!.elapsedSeconds = 450
    precondition(
      NotificationPlan.make(
        preferences: preferences, snapshot: snapshot, now: now, calendar: calendar
      ).first { $0.kind == .focus }!.date == now.addingTimeInterval(150))
    snapshot.focus!.elapsedSeconds = 600
    precondition(
      !NotificationPlan.make(
        preferences: preferences, snapshot: snapshot, now: now, calendar: calendar
      ).contains { $0.kind == .focus })
    snapshot.focus = nil

    preferences.quietHours = true
    func at(_ hour: Int, _ minute: Int = 0) -> Date {
      calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now)!
    }
    precondition(preferences.isQuiet(at(22), calendar: calendar))
    precondition(preferences.isQuiet(at(7, 59), calendar: calendar))
    precondition(!preferences.isQuiet(at(8), calendar: calendar))
    precondition(!preferences.isQuiet(at(21, 59), calendar: calendar))
    preferences.planTime = 7 * 60
    plan = NotificationPlan.make(
      preferences: preferences, snapshot: snapshot, now: now, calendar: calendar)
    precondition(!plan.contains { $0.kind == .plan }, "Quiet reminders are skipped, not moved")
    preferences.quietStart = 12 * 60
    preferences.quietEnd = 13 * 60
    precondition(preferences.isQuiet(at(12, 30), calendar: calendar))
    precondition(!preferences.isQuiet(at(11, 59), calendar: calendar))
    preferences.quietEnd = preferences.quietStart
    precondition(!preferences.isQuiet(at(12), calendar: calendar))
    preferences.quietHours = false
    preferences.planTime = 9 * 60
    plan = NotificationPlan.make(
      preferences: preferences, snapshot: snapshot, now: at(9, 30), calendar: calendar)
    precondition(
      plan.filter { $0.kind == .plan }.count == 6, "No stale morning reminder after launch")
    preferences.sound = false
    precondition(
      NotificationPlan.make(
        preferences: preferences, snapshot: snapshot, now: now, calendar: calendar
      ).allSatisfy { !$0.sound })

    let ny = NotificationPlan.calendar(timeZone: TimeZone(identifier: "America/New_York")!)
    let beforeDST = iso.date(from: "2026-03-07T12:00:00Z")!
    let dstPlan = NotificationPlan.make(
      preferences: preferences, snapshot: snapshot, now: beforeDST, calendar: ny
    ).filter { $0.kind == .plan }
    precondition(dstPlan.count == 7)
    precondition(dstPlan[1].date.timeIntervalSince(dstPlan[0].date) == 23 * 60 * 60)
    precondition(dstPlan.allSatisfy { ny.component(.hour, from: $0.date) == 9 })
    preferences.planTime = 2 * 60 + 30
    let missingHour = NotificationPlan.make(
      preferences: preferences, snapshot: snapshot, now: beforeDST.addingTimeInterval(-6 * 60 * 60),
      calendar: ny
    ).filter { $0.kind == .plan }
    precondition(missingHour.count == 7 && Set(missingHour.map(\.id)).count == 7)

    preferences.planTime = -200
    preferences.quietStart = 99999
    precondition(preferences.normalized.planTime == 0 && preferences.normalized.quietStart == 1439)
    let saved = try JSONEncoder().encode(preferences)
    let restored = try JSONDecoder().decode(NotificationPreferences.self, from: saved)
    precondition(restored == preferences)
    snapshot.ready = false
    precondition(
      NotificationPlan.make(
        preferences: preferences, snapshot: snapshot, now: now, calendar: calendar
      ).isEmpty)
    print(
      "Notification plan OK: defaults, 7-day horizon, deduplication, fulfilled plans/reviews/deadlines, pause/resume, expired sessions, quiet hours, sound, DST, persistence"
    )
  }
}
