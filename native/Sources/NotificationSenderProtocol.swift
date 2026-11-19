import Foundation

enum NotificationSenderCommand: String, Codable {
  case settings, authorize, reconcile, test, close
}

struct NotificationSenderRequest: Codable {
  var command: NotificationSenderCommand
  var preferences: NotificationPreferences? = nil
  var snapshot: NotificationSnapshot? = nil
  var plan: [PlannedNotification]? = nil
  var test: PlannedNotification? = nil
}

struct NotificationSenderResponse: Codable {
  var error: String? = nil
  var authorization: Int? = nil
  var bannersEnabled: Bool? = nil
  var canDeliver: Bool? = nil
}

enum NotificationRoute {
  static func url(for kind: NotificationKind) -> URL? {
    URL(string: "ascend-notification://open/\(kind.rawValue)")
  }

  static func kind(for url: URL) -> NotificationKind? {
    guard url.scheme == "ascend-notification", url.host == "open" else { return nil }
    return NotificationKind(rawValue: url.path.dropFirst().description)
  }
}
