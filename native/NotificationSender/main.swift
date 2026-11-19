import AppKit
import Foundation
import UserNotifications

@MainActor private final class Sender: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private let center = UNUserNotificationCenter.current()
  private let serving = CommandLine.arguments.contains("--serve")
  private var preferences = NotificationPreferences()
  private var snapshot = NotificationSnapshot()
  private var installed: [String: PlannedNotification] = [:]
  private let testID = "ascend.test"

  func applicationWillFinishLaunching(_ notification: Notification) {
    center.delegate = self
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard serving else {
      // A notification click can launch the helper even when ASCEND is closed.
      DispatchQueue.main.asyncAfter(deadline: .now() + 10) { NSApp.terminate(nil) }
      return
    }
    DispatchQueue.global(qos: .utility).async {
      while let line = readLine() {
        let ready = DispatchSemaphore(value: 0)
        Task { @MainActor in
          await self.respond(to: line)
          ready.signal()
        }
        ready.wait()
      }
      Task { @MainActor in
        await self.close()
        NSApp.terminate(nil)
      }
    }
  }

  private func respond(to line: String) async {
    let reply: NotificationSenderResponse
    do {
      let request = try JSONDecoder().decode(NotificationSenderRequest.self, from: Data(line.utf8))
      reply = try await handle(request)
    } catch {
      reply = NotificationSenderResponse(error: error.localizedDescription)
    }
    guard let data = try? JSONEncoder().encode(reply) else { return }
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
  }

  private func handle(_ request: NotificationSenderRequest) async throws -> NotificationSenderResponse {
    switch request.command {
    case .settings, .authorize:
      if request.command == .authorize { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
      let settings = await center.notificationSettings()
      let alerts = settings.alertSetting == .enabled
      return NotificationSenderResponse(
        authorization: settings.authorizationStatus.rawValue,
        bannersEnabled: alerts,
        canDeliver: (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
          && (alerts || settings.notificationCenterSetting == .enabled))
    case .reconcile:
      guard let preferences = request.preferences, let snapshot = request.snapshot, let plan = request.plan else {
        throw CocoaError(.coderValueNotFound)
      }
      self.preferences = preferences
      self.snapshot = snapshot
      try await reconcile(plan)
    case .test:
      guard let test = request.test else { throw CocoaError(.coderValueNotFound) }
      try await center.add(makeRequest(test, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
    case .close:
      await close()
    }
    return NotificationSenderResponse()
  }

  private func reconcile(_ plan: [PlannedNotification]) async throws {
    let pending = await center.pendingNotificationRequests()
    let wanted = Set(plan.map(\.id))
    var obsolete = pending.map(\.identifier).filter {
      $0.hasPrefix(NotificationPlan.prefix) && !wanted.contains($0)
    }
    if !preferences.enabled { obsolete.append(testID) }
    center.removePendingNotificationRequests(withIdentifiers: obsolete)

    let delivered = await center.deliveredNotifications()
    let stale = delivered.filter { item in
      let id = item.request.identifier
      guard id.hasPrefix(NotificationPlan.prefix) || id == testID else { return false }
      if !preferences.enabled { return true }
      let kind = (item.request.content.userInfo["kind"] as? String).flatMap(NotificationKind.init(rawValue:))
      let day = String(id.suffix(10))
      switch kind {
      case .plan: return !preferences.dailyPlan || snapshot.planDays.contains(day)
      case .review: return !preferences.dailyReview || snapshot.journalDays.contains(day)
      case .deadline: return !preferences.deadlines || !snapshot.quests.contains { $0.day == day }
      case .focus: return !preferences.focus || snapshot.focus?.id != item.request.content.userInfo["sessionID"] as? String
      default: return false
      }
    }.map { $0.request.identifier }
    center.removeDeliveredNotifications(withIdentifiers: stale)

    let existing = Set(pending.map(\.identifier))
    var next: [String: PlannedNotification] = [:]
    var failure: Error?
    for item in plan {
      if existing.contains(item.id), installed[item.id] == item {
        next[item.id] = item
        continue
      }
      guard item.date > Date() else { continue }
      let calendar = NotificationPlan.calendar()
      var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: item.date)
      components.calendar = calendar
      components.timeZone = calendar.timeZone
      do {
        try await center.add(makeRequest(item, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
        next[item.id] = item
      } catch {
        failure = error
      }
    }
    installed = next
    if let failure { throw failure }
  }

  private func makeRequest(_ item: PlannedNotification, trigger: UNNotificationTrigger) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = item.title
    content.body = item.body
    if item.sound { content.sound = .default }
    content.userInfo = ["kind": item.kind.rawValue, "sessionID": item.sessionID ?? ""]
    return UNNotificationRequest(identifier: item.id, content: content, trigger: trigger)
  }

  private func close() async {
    let focusPrefix = NotificationPlan.prefix + "focus."
    let pending = await center.pendingNotificationRequests()
    center.removePendingNotificationRequests(withIdentifiers:
      pending.map(\.identifier).filter { $0.hasPrefix(focusPrefix) || $0 == testID })
  }

  private func mayPresent(_ content: UNNotificationContent) -> Bool {
    guard preferences.enabled else { return false }
    let kind = (content.userInfo["kind"] as? String).flatMap(NotificationKind.init(rawValue:))
    if kind == .test { return true }
    let calendar = NotificationPlan.calendar()
    let now = Date()
    guard !preferences.isQuiet(now, calendar: calendar) else { return false }
    let day = NotificationPlan.dayKey(now, calendar: calendar)
    switch kind {
    case .focus:
      return preferences.focus && snapshot.focus?.running == true
        && snapshot.focus?.id == content.userInfo["sessionID"] as? String
    case .plan: return preferences.dailyPlan && !snapshot.planDays.contains(day) && snapshot.focus == nil
    case .review: return preferences.dailyReview && !snapshot.journalDays.contains(day)
    case .deadline: return preferences.deadlines && snapshot.quests.contains { $0.day == day }
    default: return false
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions {
    await MainActor.run {
      guard mayPresent(notification.request.content) else { return [] }
      var options: UNNotificationPresentationOptions = [.list, .banner]
      if preferences.sound, notification.request.content.sound != nil { options.insert(.sound) }
      return options
    }
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
  ) async {
    guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
      let raw = response.notification.request.content.userInfo["kind"] as? String,
      let kind = NotificationKind(rawValue: raw), let url = NotificationRoute.url(for: kind)
    else { return }
    await MainActor.run {
      let main = Bundle.main.bundleURL.deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
      NSWorkspace.shared.open([url], withApplicationAt: main, configuration: .init()) { _, _ in }
    }
  }
}

@main struct NotificationSenderApplication {
  @MainActor static func main() {
    let app = NSApplication.shared
    let sender = Sender()
    app.setActivationPolicy(.accessory)
    app.delegate = sender
    withExtendedLifetime(sender) { app.run() }
  }
}
