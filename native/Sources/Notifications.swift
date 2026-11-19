import AppKit
import Combine
import CoreServices
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
  private let legacyCenter = UNUserNotificationCenter.current()
  private var senderProcess: EngineProcess?
  private weak var store: Store?
  private var subscriptions = Set<AnyCancellable>()
  private var snapshot = NotificationSnapshot()
  private var lastKey = ""
  private var desired: [PlannedNotification] = []
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
  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    preferences =
      defaults.data(forKey: Self.preferencesKey)
      .flatMap { try? JSONDecoder().decode(NotificationPreferences.self, from: $0) }?.normalized
      ?? NotificationPreferences()
    super.init()
    legacyCenter.delegate = self
  }
  func start(store: Store) {
    guard self.store == nil else { return }
    self.store = store
    // An upgraded installation may still have requests scheduled under the main app.
    Task { [legacyCenter] in
      let pending = await legacyCenter.pendingNotificationRequests()
      let obsolete = pending.map(\.identifier).filter {
        $0.hasPrefix(NotificationPlan.prefix) || $0 == "ascend.test"
      }
      legacyCenter.removePendingNotificationRequests(withIdentifiers: obsolete)
    }
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
      do {
        var settings = try await send(.init(command: .settings))
        guard !Task.isCancelled else { return }
        let shouldRequest = permissionRequested
        permissionRequested = false
        if shouldRequest, preferences.enabled,
          settings.authorization == UNAuthorizationStatus.notDetermined.rawValue
        {
          requesting = true
          defer { requesting = false }
          settings = try await send(.init(command: .authorize))
        }
        guard !Task.isCancelled else { return }
        authorization = settings.authorization.flatMap(UNAuthorizationStatus.init(rawValue:)) ?? .notDetermined
        bannersEnabled = settings.bannersEnabled == true
        canDeliver = settings.canDeliver == true
        reconcile(force: true)
      } catch {
        guard !Task.isCancelled else { return }
        self.error = error.localizedDescription
      }
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
  private func send(_ request: NotificationSenderRequest) async throws -> NotificationSenderResponse {
    let process: EngineProcess
    if let senderProcess {
      process = senderProcess
    } else {
      let bundleURL = Bundle.main.bundleURL
        .appendingPathComponent("Contents/Helpers/ASCEND Notifications.app", isDirectory: true)
      guard let executable = Bundle(url: bundleURL)?.executableURL
      else { throw CocoaError(.fileNoSuchFile) }
      _ = LSRegisterURL(bundleURL as CFURL, true)
      process = try EngineProcess(executableURL: executable, arguments: ["--serve"], timeout: 90)
      senderProcess = process
    }
    let requestData = try JSONEncoder().encode(request)
    guard let payload = try JSONSerialization.jsonObject(with: requestData) as? [String: Any]
    else { throw CocoaError(.coderInvalidValue) }
    let response: NotificationSenderResponse
    do {
      response = try await withCheckedThrowingContinuation { continuation in
        process.send(payload, decoding: NotificationSenderResponse.self) { continuation.resume(with: $0) }
      }
    } catch {
      if senderProcess === process { senderProcess = nil }
      throw error
    }
    if let error = response.error {
      throw NSError(domain: "ASCENDNotifications", code: 1, userInfo: [NSLocalizedDescriptionKey: error])
    }
    return response
  }

  private func drain() {
    guard drainTask == nil else { return }
    // Serialize OS changes so a newer plan finishes after any outdated additions.
    drainTask = Task { [weak self] in
      guard let self else { return }
      defer { drainTask = nil }
      while dirty, !terminating {
        dirty = false
        do {
          _ = try await send(.init(command: .reconcile, preferences: preferences, snapshot: snapshot, plan: desired))
        } catch {
          self.error = error.localizedDescription
        }
      }
    }
  }

  func sendTest() {
    guard !closing, preferences.enabled, canDeliver, !testing else { return }
    testing = true
    Task { [weak self] in
      guard let self else { return }
      let test = PlannedNotification(
        id: "ascend.test", kind: .test, title: "ASCEND",
        body: L("Notifications are ready. You're all set."), date: Date(), sound: preferences.sound)
      do {
        _ = try await send(.init(command: .test, test: test))
      } catch {
        self.error = error.localizedDescription
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
    desired.removeAll { $0.kind == .focus }
    dirty = true
    drain()
    var finished = false
    let finish = { [weak self] in
      guard !finished else { return }
      finished = true
      self?.terminating = true
      self?.senderProcess?.shutdown()
      completion()
    }
    let pending = drainTask
    Task { [weak self] in
      await pending?.value
      if !finished, let self, senderProcess != nil {
        _ = try? await send(.init(command: .close))
      }
      finish()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() }
  }
  func clearError() { error = nil }

  func openRoute(_ url: URL) {
    if let kind = NotificationRoute.kind(for: url) { navigate(to: kind) }
  }

  // Suppress a legacy request that is already being delivered during migration.
  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification
  ) async -> UNNotificationPresentationOptions { [] }

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
      switch kind {
      case .review: store.navigate(.journal)
      case .deadline: store.navigate(.quests)
      default: store.navigate(.dashboard)
      }
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
