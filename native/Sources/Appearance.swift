import AppKit
import SwiftUI

/// Tracks the macOS appearance so "System" can apply a concrete light or dark scheme.
/// Passing nil to preferredColorScheme leaves part of the window on the previous theme
/// until the window resigns key or the tab changes.
final class SystemAppearance: ObservableObject {
  @Published private(set) var scheme: ColorScheme = SystemAppearance.current
  private var token: NSObjectProtocol?
  init() {
    token = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.scheme = SystemAppearance.current
    }
  }
  static var current: ColorScheme {
    UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
  }
  func resolved(_ stored: String) -> ColorScheme {
    switch stored {
    case "dark": .dark
    case "light": .light
    default: scheme
    }
  }
  deinit {
    if let token { DistributedNotificationCenter.default().removeObserver(token) }
  }
}

enum AppStyle {
  static let accent = Color(red: 0.18, green: 0.50, blue: 0.88)
  static let mint = Color(red: 0.21, green: 0.66, blue: 0.52)
  static let amber = Color(red: 0.81, green: 0.53, blue: 0.21)
  static let blue = Color(red: 0.28, green: 0.56, blue: 0.84)
  static let choice = accent
}

/// Keep the native switch at the trailing edge, independently of label length.
struct TrailingSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 16) {
      configuration.label.frame(maxWidth: .infinity, alignment: .leading)
      Toggle(isOn: configuration.$isOn) { configuration.label }
        .labelsHidden().toggleStyle(.switch).fixedSize()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

enum AppChrome {
  static func canvas(style: String, scheme: ColorScheme) -> Color {
    guard style == "colorful", scheme != .dark else { return Color(nsColor: .windowBackgroundColor) }
    return scheme == .dark
      ? Color(red: 0.11, green: 0.13, blue: 0.12)
      : Color(red: 0.82, green: 0.875, blue: 0.83)
  }
}

struct Surface<Content: View>: View {
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  @AppStorage("style") private var style = "minimal"
  var padding: CGFloat = 22
  var fillHeight = false
  @ViewBuilder let content: () -> Content
  private var colors: [Color] {
    if style == "colorful", scheme != .dark {
      return scheme == .dark
        ? [Color(red: 0.18, green: 0.22, blue: 0.19), Color(red: 0.14, green: 0.17, blue: 0.15)]
        : [Color(red: 0.97, green: 0.985, blue: 0.965), Color(red: 0.925, green: 0.955, blue: 0.925)]
    }
    return [
      scheme == .dark ? Color(white: 0.20) : Color.white,
      scheme == .dark ? Color(white: 0.16) : Color(red: 0.985, green: 0.988, blue: 0.998),
    ]
  }
  var body: some View {
    let _ = locale
    content().padding(padding).frame(
      maxWidth: .infinity, maxHeight: fillHeight ? .infinity : nil, alignment: .topLeading
    )
    .background {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(
          LinearGradient(
            colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(
            scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.055),
            lineWidth: 1)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.16 : 0.045), radius: 14, x: 0, y: 5)
    }
  }
}

struct HintButton: View {
  @Environment(\.locale) private var locale
  let text: String
  @State private var shown = false
  var body: some View {
    let _ = locale
    Button {
      shown.toggle()
    } label: {
      Image(systemName: "exclamationmark.circle")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 16, height: 16)
    }
    .buttonStyle(.borderless)
    .accessibilityLabel("Details")
    .popover(isPresented: $shown) {
      Text(L(text))
        .font(.system(size: 13))
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 260, alignment: .leading)
        .padding(14)
    }
  }
}

struct PencilButton: View {
  var label: LocalizedStringKey
  var action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: "pencil")
        .font(.system(size: 12, weight: .semibold))
        .frame(width: 14, height: 14)
    }
    .buttonStyle(.bordered)
    .controlSize(.small)
    .help(label)
    .accessibilityLabel(Text(label))
  }
}

struct SectionCard<Content: View>: View {
  @Environment(\.locale) private var locale
  let title: String
  var fillHeight = false
  var detail: String? = nil
  var actionTitle: String? = nil
  var pencil = false
  var action: (() -> Void)? = nil
  var accessory: AnyView? = nil
  @ViewBuilder let content: () -> Content
  var body: some View {
    let _ = locale
    Surface(fillHeight: fillHeight) {
      VStack(alignment: .leading, spacing: 20) {
        HStack(alignment: .center, spacing: 8) {
          Text(L(title)).font(.system(size: 15, weight: .semibold))
          if let accessory { accessory }
          Spacer(minLength: 12)
          if let detail { Text(L(detail)).font(.system(size: 12)).foregroundStyle(.secondary) }
          if let actionTitle, let action {
            if pencil {
              PencilButton(label: LocalizedStringKey(actionTitle), action: action)
            } else {
              Button(L(actionTitle), action: action).buttonStyle(.borderless).controlSize(.small)
            }
          }
        }
        content()
      }
    }
  }
}

struct ScreenLayout<Content: View>: View {
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  @AppStorage("style") private var style = "minimal"
  @ViewBuilder let content: () -> Content
  var body: some View {
    let _ = locale
    ScrollView {
      VStack(alignment: .leading, spacing: 22) { content() }
        .frame(maxWidth: 1180, alignment: .leading).padding(28).frame(
          maxWidth: .infinity, alignment: .top)
    }
    .modifier(SoftScrollEdge())
    .background(AppChrome.canvas(style: style, scheme: scheme))
  }
}

/// Full-height pages use the same scrolling root as Analytics and Balance,
/// so the window toolbar keeps one scroll-edge treatment instead of a solid bar.
struct PageFrame<Content: View>: View {
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  @AppStorage("style") private var style = "minimal"
  @ViewBuilder let content: () -> Content
  var body: some View {
    let _ = locale
    page.background(AppChrome.canvas(style: style, scheme: scheme))
  }
  @ViewBuilder private var page: some View {
    if #available(macOS 14, *) {
      ScrollView { content().containerRelativeFrame(.vertical, alignment: .top) }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(SoftScrollEdge())
    } else {
      ScrollView { content().frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top) }
    }
  }
}

private struct SoftScrollEdge: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content.scrollEdgeEffectStyle(.soft, for: .top)
    } else {
      content
    }
  }
}

struct ThemeChooser: View {
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  @AppStorage("appearance") private var appearance = "system"
  @AppStorage("style") private var style = "minimal"
  var body: some View {
    let _ = locale
    VStack(spacing: 16) {
      HStack(spacing: 8) {
        themeTab("System", "circle.lefthalf.filled", "system")
        themeTab("Dark", "moon.stars", "dark")
        themeTab("Light", "sun.max", "light")
      }
      if scheme != .dark {
        HStack(alignment: .top, spacing: 16) {
          styleCard("minimal", "Minimal")
          styleCard("colorful", "Colorful")
        }
      }
    }
  }
  private func themeTab(_ title: String, _ symbol: String, _ value: String) -> some View {
    let selected = appearance == value
    return Button {
      appearance = value
    } label: {
      HStack(spacing: 6) {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium))
        Text(L(title)).font(.system(size: 14, weight: .medium))
      }
      .frame(maxWidth: .infinity)
      .padding(.vertical, 9)
      .foregroundStyle(selected ? AppStyle.choice : Color.primary.opacity(0.82))
      .background {
        Capsule().fill(
          scheme == .dark
            ? Color.white.opacity(selected ? 0.14 : 0.06)
            : Color.white.opacity(selected ? 1 : 0.62))
      }
      .overlay {
        Capsule().strokeBorder(
          selected ? AppStyle.choice : Color.primary.opacity(0.06), lineWidth: selected ? 1.6 : 1)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
  private func styleCard(_ value: String, _ title: String) -> some View {
    let selected = style == value
    return Button {
      style = value
    } label: {
      VStack(spacing: 10) {
        stylePreview(value == "colorful")
          .frame(maxWidth: .infinity, minHeight: 118, maxHeight: 118)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
              .strokeBorder(selected ? AppStyle.choice : Color.clear, lineWidth: 2)
          }
          .shadow(color: .black.opacity(scheme == .dark ? 0.2 : 0.05), radius: 8, y: 3)
        Text(L(title))
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(selected ? AppStyle.choice : Color.primary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
  @ViewBuilder private func stylePreview(_ colorful: Bool) -> some View {
    if colorful {
      ZStack {
        (scheme == .dark
          ? Color(red: 0.11, green: 0.13, blue: 0.12)
          : Color(red: 0.82, green: 0.875, blue: 0.83))
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(
            scheme == .dark
              ? Color(red: 0.18, green: 0.22, blue: 0.19)
              : Color(red: 0.94, green: 0.97, blue: 0.94))
          .padding(16)
        VStack(alignment: .leading, spacing: 7) {
          Capsule().fill(AppStyle.choice).frame(width: 54, height: 8)
          Capsule().fill(AppStyle.mint).frame(width: 78, height: 8)
          Capsule().fill(AppStyle.amber).frame(width: 42, height: 8)
        }
      }
    } else {
      VStack(alignment: .leading, spacing: 8) {
        ForEach(0..<3, id: \.self) { index in
          RoundedRectangle(cornerRadius: 3)
            .fill(Color.primary.opacity(0.16))
            .frame(width: 64 + CGFloat(index) * 18, height: 6)
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(scheme == .dark ? Color(white: 0.20) : Color.white)
    }
  }
}

struct StatusPill: View {
  @Environment(\.locale) private var locale
  let title: String
  var color: Color = AppStyle.accent
  var symbol: String? = nil
  var body: some View {
    let _ = locale
    HStack(spacing: 5) {
      if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
      Text(L(title)).font(.system(size: 11, weight: .medium))
    }
    .foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5)
    .background(color.opacity(0.11), in: Capsule()).fixedSize()
  }
}

struct ProgressTrack: View {
  @Environment(\.locale) private var locale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let value: Double
  var total: Double = 100
  var color: Color = AppStyle.accent
  var height: CGFloat = 6
  private var fraction: Double {
    guard value.isFinite, total.isFinite, total > 0 else { return 0 }
    return min(max(value / total, 0), 1)
  }
  var body: some View {
    let _ = locale
    GeometryReader { proxy in
      ZStack(alignment: .leading) {
        Capsule().fill(Color.primary.opacity(0.065))
        Capsule().fill(
          LinearGradient(
            colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing)
        ).frame(width: max(0, proxy.size.width * fraction))
      }
    }.frame(height: height).animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: fraction)
      .accessibilityElement().accessibilityLabel("Progress").accessibilityValue(
        L("%d percent", Int(fraction * 100)))
  }
}

struct EmptyState: View {
  @Environment(\.locale) private var locale
  let symbol: String
  let title: String
  let message: String
  var buttonTitle: String? = nil
  var compact = false
  var action: (() -> Void)? = nil
  var body: some View {
    let _ = locale
    VStack(spacing: compact ? 10 : 14) {
      Image(systemName: symbol).font(.system(size: compact ? 22 : 27, weight: .light))
        .foregroundStyle(AppStyle.accent)
        .frame(width: compact ? 46 : 58, height: compact ? 46 : 58)
        .background(
          AppStyle.accent.opacity(0.085),
          in: RoundedRectangle(cornerRadius: compact ? 13 : 17, style: .continuous))
      VStack(spacing: 6) {
        Text(L(title)).font(.system(size: compact ? 14 : 17, weight: .semibold)).foregroundStyle(
          .primary)
        Text(L(message)).font(.system(size: 13)).foregroundStyle(.secondary).lineSpacing(3)
          .fixedSize(
            horizontal: false, vertical: true)
      }.frame(maxWidth: 330)
      if let buttonTitle, let action {
        Button(L(buttonTitle), action: action).buttonStyle(.borderedProminent).controlSize(.large)
          .padding(.top, 5)
      }
    }.multilineTextAlignment(.center).padding(.vertical, compact ? 14 : 36).padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: compact ? 145 : 260)
  }
}

struct RowDivider: View {
  @Environment(\.locale) private var locale
  var body: some View { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 1) }
}
