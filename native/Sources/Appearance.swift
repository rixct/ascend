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
    Color(nsColor: windowBackground(style: style, scheme: scheme))
  }

  static func windowBackground(style: String, scheme: ColorScheme) -> NSColor {
    if scheme == .dark {
      return NSColor(srgbRed: 0.106, green: 0.118, blue: 0.137, alpha: 1)
    }
    if style == "colorful" {
      return NSColor(srgbRed: 0.919, green: 0.947, blue: 0.928, alpha: 1)
    }
    return NSColor(srgbRed: 0.967, green: 0.974, blue: 0.981, alpha: 1)
  }

  static func island(scheme: ColorScheme) -> Color {
    scheme == .dark
      ? Color(red: 0.146, green: 0.161, blue: 0.184)
      : Color(red: 0.993, green: 0.995, blue: 0.998)
  }

  static func sidebar(scheme: ColorScheme) -> Color {
    scheme == .dark ? island(scheme: scheme) : .white
  }
}

struct Surface<Content: View>: View {
  @Environment(\.colorScheme) private var scheme
  var padding: CGFloat = 22
  @ViewBuilder let content: () -> Content
  var body: some View {
    let shape = RoundedRectangle(cornerRadius: 16)
    content().padding(padding).frame(maxWidth: .infinity, alignment: .topLeading)
      .background {
        shape.fill(AppChrome.island(scheme: scheme))
          .overlay { shape.strokeBorder(Color.primary.opacity(0.08)) }
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
        .frame(width: 26, height: 26)
    }
    .buttonStyle(.borderless)
    .help(label)
    .accessibilityLabel(Text(label))
  }
}

struct CanvasSection<Content: View>: View {
  @Environment(\.locale) private var locale
  let title: String
  var detail: String? = nil
  var actionTitle: String? = nil
  var pencil = false
  var action: (() -> Void)? = nil
  var accessory: AnyView? = nil
  @ViewBuilder let content: () -> Content
  var body: some View {
    let _ = locale
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        Text(L(title)).font(.system(size: 15, weight: .semibold)).lineLimit(2)
          .accessibilityAddTraits(.isHeader)
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
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

struct ScreenLayout<Content: View>: View {
  var maxWidth: CGFloat = 1016
  @ViewBuilder let content: () -> Content
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 28, content: content)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 20)
        .padding(.bottom, 36)
        .frame(maxWidth: .infinity, alignment: .top)
    }
    .modifier(SoftScrollEdge())
  }
}

/// Full-height pages use the same scrolling root as Analytics and Balance,
/// so the window toolbar keeps one scroll-edge treatment instead of a solid bar.
struct PageFrame<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @ViewBuilder var body: some View {
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
      .foregroundStyle(selected ? Color.primary : Color.secondary)
      .background(selected ? AppStyle.choice.opacity(0.13) : .clear, in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
  private func styleCard(_ value: String, _ title: String) -> some View {
    let selected = style == value
    return Button {
      style = value
    } label: {
      VStack(spacing: 8) {
        stylePreview(value)
          .frame(height: 88)
          .clipShape(RoundedRectangle(cornerRadius: 12))
          .overlay {
            RoundedRectangle(cornerRadius: 12)
              .strokeBorder(selected ? AppStyle.choice.opacity(0.75) : Color.primary.opacity(0.09))
          }
          .accessibilityHidden(true)
        Text(L(title))
          .font(.system(size: 13, weight: selected ? .semibold : .medium))
          .foregroundStyle(selected ? Color.primary : Color.secondary)
      }
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
  private func stylePreview(_ value: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        ForEach(0..<3, id: \.self) { index in
          Capsule().fill(Color.primary.opacity(index == 0 ? 0.25 : 0.12))
            .frame(width: 20 + CGFloat(index) * 4, height: 3)
        }
      }
      .padding(8)
      .frame(width: 48)
      .frame(maxHeight: .infinity, alignment: .top)
      .background {
        let shape = RoundedRectangle(cornerRadius: 6)
        shape.fill(AppChrome.sidebar(scheme: scheme))
          .overlay { shape.strokeBorder(Color.primary.opacity(0.09)) }
      }
      VStack(alignment: .leading, spacing: 7) {
        Capsule().fill(Color.primary.opacity(0.45)).frame(width: 24, height: 7)
        Capsule().fill(Color.primary.opacity(0.16)).frame(width: 40, height: 3)
        RowDivider()
        Capsule().fill(AppStyle.choice.opacity(0.48)).frame(width: 50, height: 4)
      }
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    .padding(8)
    .background(AppChrome.canvas(style: value, scheme: scheme))
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
  var message: String? = nil
  var buttonTitle: String? = nil
  var compact = false
  var action: (() -> Void)? = nil
  var body: some View {
    let _ = locale
    VStack(alignment: compact ? .leading : .center, spacing: compact ? 8 : 12) {
      if !compact {
        Image(systemName: symbol)
          .font(.system(size: 28, weight: .light))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
          .padding(.bottom, 4)
      }
      Text(L(title)).font(.system(size: compact ? 13 : 19, weight: compact ? .medium : .semibold))
        .foregroundStyle(compact ? Color.secondary : Color.primary)
      if let message {
        Text(L(message)).font(.system(size: 13)).foregroundStyle(.secondary)
          .lineSpacing(3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: 340, alignment: compact ? .leading : .center)
      }
      if let buttonTitle, let action {
        Button(L(buttonTitle), action: action)
          .buttonStyle(.bordered)
          .controlSize(.regular)
      }
    }
    .multilineTextAlignment(compact ? .leading : .center)
    .padding(.vertical, compact ? 8 : 58)
    .frame(maxWidth: .infinity, alignment: compact ? .leading : .center)
  }
}

enum WorkspaceHeaderLayout {
  static let controlSize: CGFloat = 40
  static let sideInset: CGFloat = 12
  static let topInset: CGFloat = 12
  static let bottomInset: CGFloat = 10
}

struct CanvasTabs: View {
  let options: [(title: LocalizedStringKey, value: Int)]
  @Binding var selection: Int
  let label: LocalizedStringKey
  @FocusState private var focused: Int?

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.value) { option in
        let selected = selection == option.value
        Button {
          selection = option.value
        } label: {
          Text(option.title)
            .font(.system(size: 12, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
              if selected {
                Capsule().fill(AppStyle.accent).frame(width: 18, height: 2)
              }
            }
        }
        .buttonStyle(.plain)
        .focused($focused, equals: option.value)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .onMoveCommand { direction in
      guard let current = options.firstIndex(where: { $0.value == selection }) else { return }
      let next: Int
      switch direction {
      case .left: next = current - 1
      case .right: next = current + 1
      default: return
      }
      guard options.indices.contains(next) else { return }
      selection = options[next].value
      focused = selection
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(Text(label))
  }
}

struct RowDivider: View {
  @Environment(\.displayScale) private var displayScale
  var body: some View {
    Rectangle().fill(Color.primary.opacity(0.12)).frame(height: 1 / displayScale)
      .accessibilityHidden(true)
  }
}
