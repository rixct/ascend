import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor final class Notifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
  @Published var preferences: NotificationPreferences {
    didSet {
      if let data = try? JSONEncoder().encode(preferences.normalized) {
        defaults.set(data, forKey: Self.preferencesKey)
      }
      reconcile(force: true)
    }
  }
  @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
  @Published private(set) var canDeliver = false
  @Published private(set) var bannersEnabled = false
  @Published private(set) var requesting = false
  @Published private(set) var testing = false
  @Published private(set) var error: String?
  private static let preferencesKey = "notifications.preferences.v1"
  private let defaults: UserDefaults
  private let center: UNUserNotificationCenter
  private weak var store: Store?
  private var subscriptions = Set<AnyCancellable>()
  private var snapshot = NotificationSnapshot()
  private var lastKey = ""
  private var desired: [PlannedNotification] = []
  private var previous: [String: PlannedNotification] = [:]
  private var dirty = false
  private var drainTask: Task<Void, Never>?
  private var closing = false
  private var terminating = false
  private var permissionRequested = false
  private var permissionTask: Task<Void, Never>?
  private var pendingRoute: NotificationKind?
  var openMainWindow: (() -> Void)?

  var needsAttention: Bool { !preferences.enabled || !canDeliver }
  var status: String {
    if !preferences.enabled { return L("Notifications are off") }
    if authorization == .denied { return L("Blocked by macOS") }
    if !canDeliver { return L("Permission is needed") }
    return L("Notifications are on")
  }
  init(defaults: UserDefaults = .standard, center: UNUserNotificationCenter = .current()) {
    self.defaults = defaults
    self.center = center
    preferences =
      defaults.data(forKey: Self.preferencesKey)
      .flatMap { try? JSONDecoder().decode(NotificationPreferences.self, from: $0) }?.normalized
      ?? NotificationPreferences()
    super.init()
    center.delegate = self
  }
  func start(store: Store) {
    guard self.store == nil else { return }
    self.store = store
    if let route = pendingRoute { navigate(to: route) }
    store.$state.combineLatest(store.$summary)
      .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
      .sink { [weak self] state, summary in
        guard let self, let state, let summary else { return }
        self.update(state: state, summary: summary)
      }.store(in: &subscriptions)
    for name in [
      NSApplication.didBecomeActiveNotification, .NSSystemTimeZoneDidChange,
      .NSCalendarDayChanged, Notification.Name("NSSystemClockDidChangeNotification"),
    ] {
      NotificationCenter.default.publisher(for: name).receive(on: RunLoop.main)
        .sink { [weak self] _ in self?.refreshAuthorization() }.store(in: &subscriptions)
    }
    NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
      .receive(on: RunLoop.main).sink { [weak self] _ in self?.reconcile() }
      .store(in: &subscriptions)
    refreshAuthorization()
  }
  private func update(state: GameState, summary: Summary) {
    let today = summary.today
    let calendar = NotificationPlan.calendar()
    let horizon = NotificationPlan.dayKey(
      calendar.date(byAdding: .day, value: 7, to: Date()) ?? Date(), calendar: calendar)
    snapshot = NotificationSnapshot(
      ready: state.settings.onboarded,
      planDays: Set(state.plans.filter { $0.day >= today && $0.day <= horizon }.map(\.day)),
      journalDays: Set(state.journal.filter { $0.day >= today && $0.day <= horizon }.map(\.day)),
      quests: state.quests.filter {
        !$0.closed && ($0.deadline ?? "") >= today && ($0.deadline ?? "") <= horizon
      }.compactMap {
        guard let deadline = $0.deadline else { return nil }
        return .init(day: deadline, title: String($0.title.prefix(70)))
      },
      focus: state.active.flatMap { active in
        guard let quest = state.quest(active.quest_id) else { return nil }
        return .init(
          id: active.id, title: quest.title, running: active.isCounting,
          goalSeconds: quest.estimate_minutes * 60, elapsedSeconds: active.elapsed_seconds)
      })
    reconcile()
  }
  func setEnabled(_ enabled: Bool) {
    preferences.enabled = enabled
    if enabled { refreshAuthorization(requestIfNeeded: true) }
  }
  func refreshAuthorization(requestIfNeeded: Bool = false) {
    if requestIfNeeded { permissionRequested = true }
    guard permissionTask == nil else { return }
    permissionTask = Task { [weak self] in
      guard let self else { return }
      defer { permissionTask = nil }
      var settings = await center.notificationSettings()
      guard !Task.isCancelled else { return }
      let shouldRequest = permissionRequested
      permissionRequested = false
      if shouldRequest, preferences.enabled, settings.authorizationStatus == .notDetermined {
        requesting = true
        defer { requesting = false }
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) } catch {
          self.error = error.localizedDescription
        }
        settings = await center.notificationSettings()
      }
      guard !Task.isCancelled else { return }
      authorization = settings.authorizationStatus
      bannersEnabled = settings.alertSetting == .enabled
      canDeliver =
        (authorization == .authorized || authorization == .provisional)
        && (settings.alertSetting == .enabled || settings.notificationCenterSetting == .enabled)
      reconcile(force: true)
    }
  }
  private func reconcile(force: Bool = false) {
    guard !closing else { return }
    let calendar = NotificationPlan.calendar()
    let key =
      snapshot.schedulingKey + "|" + NotificationPlan.dayKey(Date(), calendar: calendar)
      + "|" + calendar.timeZone.identifier + "|" + AppLanguage.current.rawValue
    guard force || key != lastKey else { return }
    lastKey = key
    desired = canDeliver ? NotificationPlan.make(preferences: preferences, snapshot: snapshot) : []
    dirty = true
    drain()
  }
  private func drain() {
    guard drainTask == nil else { return }
    // Serialize OS changes: an outdated add must finish before the latest plan removes it.
    drainTask = Task { [weak self] in
      guard let self else { return }
      defer { drainTask = nil }
      while dirty, !terminating {
        dirty = false
        let plan = desired
        let pending = await center.pendingNotificationRequests()
        if dirty || terminating { continue }
        let wanted = Set(plan.map(\.id))
        let obsolete = pending.map(\.identifier).filter {
          $0.hasPrefix(NotificationPlan.prefix) && !wanted.contains($0)
        }
        center.removePendingNotificationRequests(withIdentifiers: obsolete)
        if !preferences.enabled {
          center.removePendingNotificationRequests(withIdentifiers: ["ascend.test"])
        }
        let delivered = await center.deliveredNotifications()
        if dirty || terminating { continue }
        let stale = delivered.filter { notification in
          let id = notification.request.identifier
          guard id.hasPrefix(NotificationPlan.prefix) || id == "ascend.test" else { return false }
          if !self.preferences.enabled { return true }
          let kind = (notification.request.content.userInfo["kind"] as? String).flatMap(
            NotificationKind.init(rawValue:))
          let day = String(id.suffix(10))
          switch kind {
          case .plan: return !self.preferences.dailyPlan || self.snapshot.planDays.contains(day)
          case .review:
            return !self.preferences.dailyReview || self.snapshot.journalDays.contains(day)
          case .deadline:
            return !self.preferences.deadlines || !self.snapshot.quests.contains { $0.day == day }
          case .focus:
            return !self.preferences.focus
              || self.snapshot.focus?.id != notification.request.content.userInfo["sessionID"]
                as? String
          default: return false
          }
        }.map { $0.request.identifier }
        center.removeDeliveredNotifications(withIdentifiers: stale)
        let existing = Set(pending.map(\.identifier))
        var installed: [String: PlannedNotification] = [:]
        for item in plan {
          if dirty || terminating { break }
          if existing.contains(item.id), previous[item.id] == item {
            installed[item.id] = item
            continue
          }
          // Expired requests are never recreated as immediate, stale alerts.
          guard item.date > Date() else { continue }
          do {
            try await center.add(request(for: item))
            installed[item.id] = item
            if terminating { center.removePendingNotificationRequests(withIdentifiers: [item.id]) }
          } catch { self.error = error.localizedDescription }
        }
        // Failed replacements must be retried on the next reconciliation, even if an
        // older request with the same ID is still registered with macOS.
        previous = installed
      }
    }
  }
  private func request(for item: PlannedNotification) -> UNNotificationRequest {
    let content = UNMutableNotificationContent()
    content.title = item.title
    content.body = item.body
    if item.sound { content.sound = .default }
    content.userInfo = ["kind": item.kind.rawValue, "sessionID": item.sessionID ?? ""]
    let calendar = NotificationPlan.calendar()
    var components = calendar.dateComponents(
      [.year, .month, .day, .hour, .minute, .second], from: item.date)
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    return UNNotificationRequest(
      identifier: item.id, content: content,
      trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
  }
  func sendTest() {
    guard !closing, preferences.enabled, canDeliver, !testing else { return }
    testing = true
    Task { [weak self] in
      guard let self else { return }
      let content = UNMutableNotificationContent()
      content.title = "ASCEND"
      content.body = L("Notifications are ready. You're all set.")
      content.userInfo = ["kind": NotificationKind.test.rawValue]
      if preferences.sound { content.sound = .default }
      do {
        try await center.add(
          UNNotificationRequest(
            identifier: "ascend.test", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)))
      } catch { self.error = error.localizedDescription }
      if !preferences.enabled || terminating {
        center.removePendingNotificationRequests(withIdentifiers: ["ascend.test"])
      }
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      testing = false
    }
  }
  func openSystemSettings() {
    // macOS routes the Notifications settings pane; fall back to the Settings application.
    if let url = URL(
      string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"),
      NSWorkspace.shared.open(url)
    {
      return
    }
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
  }
  func prepareToTerminate(completion: @escaping () -> Void) {
    closing = true
    subscriptions.removeAll()
    permissionTask?.cancel()
    let focusIDs = Set(
      desired.filter { $0.kind == .focus }.map(\.id)
        + previous.values.filter { $0.kind == .focus }.map(\.id))
    desired.removeAll { $0.kind == .focus }
    dirty = true
    drain()
    var finished = false
    let finish = { [weak self] in
      guard !finished else { return }
      finished = true
      if let self {
        self.terminating = true
        self.center.removePendingNotificationRequests(
          withIdentifiers: Array(focusIDs) + ["ascend.test"])
      }
      completion()
    }
    let pending = drainTask
    Task {
      await pending?.value
      finish()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() }
  }
  func clearError() { error = nil }
  private func mayPresent(_ content: UNNotificationContent, id: String) -> Bool {
    guard preferences.enabled, canDeliver else { return false }
    let kind = (content.userInfo["kind"] as? String).flatMap(NotificationKind.init(rawValue:))
    if kind == .test { return true }
    let calendar = NotificationPlan.calendar()
    guard !preferences.isQuiet(Date(), calendar: calendar) else { return false }
    let day = NotificationPlan.dayKey(Date(), calendar: calendar)
    switch kind {
    case .focus:
      return preferences.focus && snapshot.focus?.running == true
        && snapshot.focus?.id == content.userInfo["sessionID"] as? String
    case .plan:
      return preferences.dailyPlan && !snapshot.planDays.contains(day) && snapshot.focus == nil
    case .review: return preferences.dailyReview && !snapshot.journalDays.contains(day)
    case .deadline: return preferences.deadlines && snapshot.quests.contains { $0.day == day }
    default: return false
    }
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    Task { @MainActor [weak self] in
      guard let self, mayPresent(notification.request.content, id: notification.request.identifier)
      else {
        completionHandler([])
        return
      }
      var options: UNNotificationPresentationOptions = [.banner, .list]
      if preferences.sound, notification.request.content.sound != nil { options.insert(.sound) }
      completionHandler(options)
    }
  }
  private func navigate(to kind: NotificationKind) {
    guard let store else {
      pendingRoute = kind
      return
    }
    pendingRoute = nil
    if kind == .test {
      store.openSettings()
      store.settingsTab = .notifications
    } else {
      store.navigate(kind.page)
    }
    openMainWindow?()
  }
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    Task { @MainActor [weak self] in
      defer { completionHandler() }
      guard let self, response.actionIdentifier == UNNotificationDefaultActionIdentifier,
        let raw = response.notification.request.content.userInfo["kind"] as? String,
        let kind = NotificationKind(rawValue: raw)
      else { return }
      navigate(to: kind)
    }
  }
}
