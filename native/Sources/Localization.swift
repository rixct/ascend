import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
  case english = "en"
  case russian = "ru"
  var id: String { rawValue }
  var title: String { self == .english ? "English" : "Русский" }
  var locale: Locale { Locale(identifier: self == .english ? "en_US" : "ru_RU") }
  /// The first macOS language this app can display.
  static var system: Self {
    for code in Locale.preferredLanguages {
      let id = code.lowercased()
      if id.hasPrefix("ru") { return .russian }
      if id.hasPrefix("en") { return .english }
    }
    return .english
  }
  static func resolved(_ stored: String?) -> Self {
    guard let stored, let language = Self(rawValue: stored) else { return .system }
    return language
  }
  static var current: Self {
    resolved(UserDefaults.standard.string(forKey: "language"))
  }
}

private let languageBundles: [AppLanguage: Bundle] = Dictionary(
  uniqueKeysWithValues: AppLanguage.allCases.map { language in
    let bundle =
      Bundle.main.path(forResource: language.rawValue, ofType: "lproj")
      .flatMap { Bundle(path: $0) } ?? .main
    return (language, bundle)
  })

// Plain strings from shared components use the same resources as SwiftUI's localized labels.
func L(_ key: String, _ arguments: CVarArg...) -> String {
  let language = AppLanguage.current
  let format =
    languageBundles[language]?.localizedString(forKey: key, value: key, table: nil) ?? key
  guard !arguments.isEmpty else { return format }
  return String(format: format, locale: language.locale, arguments: arguments)
}
