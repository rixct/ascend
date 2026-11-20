import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class ProfileDraft: ObservableObject {
  @Published var name = ""
  @Published var bio = ""
  @Published var avatar: String?
  @Published var minutes = 90
  @Published var growth = 10
  private var loaded = false

  @discardableResult
  func load(_ profile: Profile?, replacing: Bool = false) -> Bool {
    guard replacing || !loaded, let profile else { return false }
    loaded = true
    name = String(profile.name.prefix(64))
    bio = String((profile.bio ?? "").prefix(140))
    avatar = profile.avatar
    minutes = profile.daily_minutes
    growth = profile.growth_percent
    return true
  }

  func canSave(busy: Bool) -> Bool {
    !busy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && (1...1440).contains(minutes)
  }

  func save(store: Store, strict: Bool, then: (() -> Void)? = nil) {
    guard canSave(busy: store.busy) else { return }
    store.send(
      "settings",
      [
        "name": name, "avatar": avatar ?? "", "bio": bio, "minutes": minutes, "growth": growth,
        "strict": strict,
      ],
      then: then)
  }
}

struct SettingsView: View {
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  @EnvironmentObject var store: Store
  @AppStorage("style") private var style = "minimal"
  @AppStorage("strictModeEnabled") private var strictModeEnabled = false
  @StateObject private var draft = ProfileDraft()
  var workspaceControls: WorkspaceControls? = nil

  var body: some View {
    let _ = locale
    VStack(spacing: 0) {
      WorkspaceHeader(sidebarHidden: workspaceControls?.showSidebar != nil) {
        if let workspaceControls {
          workspaceControls
        } else {
          Color.clear.frame(width: 36).accessibilityHidden(true)
        }
        Spacer(minLength: 0)
        SettingsTabPicker()
        Spacer(minLength: 0)
        doneButton
      }
      .zIndex(1)
      settingsPage
    }
    .background {
      AppChrome.canvas(style: style, scheme: scheme).ignoresSafeArea()
    }
    .onAppear(perform: adoptProfile)
    .onChange(of: store.state?.settings.name) { _ in adoptProfile() }
    .onChange(of: store.profileGeneration) { _ in
      if draft.load(store.state?.settings, replacing: true) {
        strictModeEnabled = store.state?.settings.strict_mode == true
      }
    }
  }
  private func finishSettings() {
    draft.save(store: store, strict: strictModeEnabled) {
      store.navigate(.character)
    }
  }
  private func adoptProfile() {
    guard draft.load(store.state?.settings) else { return }
    strictModeEnabled = store.state?.settings.strict_mode == true
  }
  @ViewBuilder private var doneButton: some View {
    let enabled = draft.canSave(busy: store.busy)
    if #available(macOS 26, *) {
      GlassIconButton(symbol: "checkmark", title: "Done", action: finishSettings)
        .disabled(!enabled)
    } else {
      Button(action: finishSettings) {
        Label("Done", systemImage: "checkmark").labelStyle(.iconOnly)
      }
      .help("Done")
      .disabled(!enabled)
    }
  }
  private var settingsPage: some View {
    Group {
      switch store.settingsTab {
      case .general: GeneralSettings(draft: draft)
      case .notifications: NotificationSettings()
      case .shortcuts: ShortcutSettings()
      case .data: DataSettings()
      case .rules: RulesSettings()
      }
    }
    .id(store.settingsTab)
    .animation(nil, value: store.settingsTab)
    .frame(maxWidth: 760)
    .padding(.horizontal, 10)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
  }
}

struct GeneralSettings: View {
  @EnvironmentObject var notifications: Notifications
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  @ObservedObject var draft: ProfileDraft
  @AppStorage("language") private var language = "system"
  @State private var imageError: String?
  @State private var systemError: String?
  @AppStorage("launchAtLogin") private var launchAtLogin = false
  @AppStorage("runInBackground") private var runInBackground = true
  @AppStorage("strictModeEnabled") private var strictModeEnabled = false
  var body: some View {
    let _ = locale
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          SettingsGroup {
            HStack(alignment: .center, spacing: 14) {
              Button(action: pickPhoto) {
                SettingsAvatar(encodedImage: draft.avatar)
              }
              .buttonStyle(.plain)
              .help("Change photo…")
              .contextMenu {
                Button("Change photo…", action: pickPhoto)
                if draft.avatar != nil {
                  Button("Remove photo", role: .destructive) { draft.avatar = nil }
                }
              }
              VStack(alignment: .leading, spacing: 8) {
                FlatField(text: $draft.name, prompt: L("Nickname"), limit: 64, onSubmit: save)
                Rectangle().fill(Color.primary.opacity(0.14)).frame(maxWidth: .infinity).frame(
                  height: 1)
                FlatField(text: $draft.bio, prompt: L("Bio"), limit: 140, onSubmit: save)
              }
              .frame(maxWidth: .infinity, alignment: .leading)
            }
          }
          SettingsGroup {
            HStack {
              SettingsLabel("Daily time", symbol: "clock")
              Spacer()
              TextField("", value: $draft.minutes, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .frame(width: 72)
                .accessibilityLabel("Daily time")
                .onSubmit(save)
            }
            RowDivider().padding(.vertical, 12)
            HStack(spacing: 16) {
              SettingsLabel("Workload increase", symbol: "chart.line.uptrend.xyaxis")
              Spacer(minLength: 12)
              PercentageControl(value: $draft.growth)
            }
          }
          SettingsGroup {
            SettingsLabel("Appearance", symbol: "paintpalette").padding(.bottom, 12)
            ThemeChooser()
            RowDivider().padding(.vertical, 14)
            HStack {
              SettingsLabel("Language", symbol: "globe")
              Spacer()
              Picker("Language", selection: $language) {
                Text("System").tag("system")
                ForEach(AppLanguage.allCases) { Text(verbatim: $0.title).tag($0.rawValue) }
              }
              .labelsHidden()
              .pickerStyle(.menu)
              .fixedSize()
            }
          }
          SettingsGroup {
            Toggle(isOn: launchAtLoginBinding) { SettingsLabel("Launch at login", symbol: "power") }
            RowDivider().padding(.vertical, 12)
            Toggle(isOn: $runInBackground) {
              SettingsLabel("Run in background", symbol: "menubar.rectangle")
            }
          }
          SettingsGroup {
            Toggle(isOn: strictModeBinding) {
              HStack(spacing: 6) {
                SettingsLabel("Strict mode", symbol: "camera")
                HintButton(
                  text: "Sessions count only while the camera confirms you are present. Manual time entry is turned off. Video is processed on this Mac and is not recorded."
                )
                Spacer(minLength: 0)
              }
            }.disabled(!draft.canSave(busy: store.busy))
          }
          SettingsGroup {
            Button {
              store.settingsTab = .notifications
            } label: {
              HStack(spacing: 6) {
                SettingsLabel("Notifications", symbol: "bell")
                if notifications.needsAttention {
                  Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(AppStyle.amber)
                }
                Spacer(minLength: 12)
                Text(notifications.status).font(.system(size: 12)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(
                  .secondary)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      RowDivider()
      Text(
        "ASCEND \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")"
      )
      .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 22).padding(.vertical, 14)
    }.onAppear(perform: refreshLaunchAtLogin)
    .onChange(of: store.error) { error in
      if error != nil { strictModeEnabled = store.state?.settings.strict_mode == true }
    }
    .alert(
      "Unable to open photo",
      isPresented: Binding(
        get: { imageError != nil }, set: { if !$0 { imageError = nil } }
      )
    ) {
      Button("OK") { imageError = nil }
    } message: {
      Text(imageError ?? "")
    }
    .alert(
      "Unable to change login item",
      isPresented: Binding(
        get: { systemError != nil }, set: { if !$0 { systemError = nil } })
    ) {
      Button("OK") { systemError = nil }
    } message: {
      Text(systemError ?? "")
    }
  }
  private var launchAtLoginBinding: Binding<Bool> {
    Binding(get: { launchAtLogin }, set: { updateLaunchAtLogin($0) })
  }
  private func refreshLaunchAtLogin() {
    switch SMAppService.mainApp.status {
    case .enabled, .requiresApproval: launchAtLogin = true
    default: launchAtLogin = false
    }
  }
  private func updateLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
      } else if [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) {
        try SMAppService.mainApp.unregister()
      }
      launchAtLogin = enabled
      if SMAppService.mainApp.status == .requiresApproval {
        SMAppService.openSystemSettingsLoginItems()
      }
    } catch {
      refreshLaunchAtLogin()
      systemError = error.localizedDescription
    }
  }
  private var strictModeBinding: Binding<Bool> {
    Binding(
      get: { strictModeEnabled },
      set: { value in
        guard draft.canSave(busy: store.busy) else { return }
        strictModeEnabled = value
        persist(strict: value)
      })
  }
  private func save() { persist(strict: nil) }
  private func persist(strict: Bool?) {
    draft.save(store: store, strict: strict ?? strictModeEnabled)
  }
  private func pickPhoto() {
    AvatarPicker.choose { result in
      switch result {
      case .success(let selected): if let selected { draft.avatar = selected }
      case .failure(let error): imageError = error.localizedDescription
      }
    }
  }
}

private struct PercentageControl: View {
  @Binding var value: Int
  var body: some View {
    HStack(spacing: 0) {
      adjustment("minus", label: "Decrease workload", disabled: value <= 0) { value = max(0, value - 5) }
      Text("\(value)%")
        .font(.system(size: 13, weight: .medium).monospacedDigit())
        .frame(width: 46)
        .accessibilityLabel("Workload increase")
        .accessibilityValue("\(value)%")
      adjustment("plus", label: "Increase workload", disabled: value >= 15) { value = min(15, value + 5) }
    }
    .padding(3)
    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
    }
    .fixedSize()
  }
  private func adjustment(
    _ symbol: String, label: LocalizedStringKey, disabled: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        .frame(width: 26, height: 26).contentShape(RoundedRectangle(cornerRadius: 5))
    }
    .buttonStyle(.borderless).foregroundStyle(AppStyle.accent)
    .disabled(disabled).accessibilityLabel(label).help(label)
  }
}

/// A single-line field with a fixed height and no focus ring, so clicking it does not shift the text.
private struct FlatField: NSViewRepresentable {
  @Binding var text: String
  var prompt: String
  var limit: Int
  var onSubmit: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, limit: limit, onSubmit: onSubmit)
  }
  func makeNSView(context: Context) -> FlatTextField {
    let field = FlatTextField()
    field.isBordered = false
    field.isBezeled = false
    field.drawsBackground = false
    field.focusRingType = .none
    field.font = .systemFont(ofSize: 16)
    field.placeholderString = prompt
    field.stringValue = text
    field.delegate = context.coordinator
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.cell?.wraps = false
    field.cell?.isScrollable = true
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
  }
  func updateNSView(_ field: FlatTextField, context: Context) {
    if field.stringValue != text { field.stringValue = text }
    field.placeholderString = prompt
    context.coordinator.text = $text
    context.coordinator.limit = limit
    context.coordinator.onSubmit = onSubmit
  }

  static func dismantleNSView(_ field: FlatTextField, coordinator: Coordinator) {
    field.delegate = nil
    coordinator.onSubmit = {}
    coordinator.text = .constant("")
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var text: Binding<String>
    var limit: Int
    var onSubmit: () -> Void
    init(text: Binding<String>, limit: Int, onSubmit: @escaping () -> Void) {
      self.text = text
      self.limit = limit
      self.onSubmit = onSubmit
    }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSTextField else { return }
      if field.stringValue.count > limit {
        field.stringValue = String(field.stringValue.prefix(limit))
      }
      if text.wrappedValue != field.stringValue { text.wrappedValue = field.stringValue }
    }
    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
    ) -> Bool {
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        onSubmit()
        return true
      }
      return false
    }
  }
}

private final class FlatTextField: NSTextField {
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: 22)
  }
}

struct SettingsGroup<Content: View>: View {
  @ViewBuilder let content: () -> Content
  var body: some View {
    VStack(alignment: .leading, spacing: 0) { content() }
      .padding(.bottom, 14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .bottom) {
        RowDivider().allowsHitTesting(false)
      }
  }
}

private struct SettingsAvatar: View {
  let encodedImage: String?
  private var image: NSImage? {
    AvatarImages.shared.image(for: encodedImage)
  }
  var body: some View {
    ZStack {
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        Color(white: 0.62)
      }
      Color.black.opacity(0.28)
      Image(systemName: "camera")
        .font(.system(size: 18, weight: .regular))
        .foregroundStyle(.white)
    }
    .frame(width: 58, height: 58)
    .clipShape(Circle())
    .accessibilityLabel("Profile photo")
  }
}

struct ShortcutSettings: View {
  @Environment(\.locale) private var locale
  @AppStorage("shortcutsEnabled") private var enabled = true
  private let shortcuts = [
    ("Today", "⌘1", "sun.max"),
    ("Skills", "⌘2", "point.3.connected.trianglepath.dotted"),
    ("Quests", "⌘3", "checklist"), ("Balance", "⌘4", "scale.3d"),
    ("New quest", "⌘N", "plus.circle"),
    ("Journal", "⌘J", "book.closed"), ("Focus mode", "⌘F", "viewfinder"),
    ("Pause / resume", "⌘↩", "playpause"),
    ("Save form", "⌘S", "square.and.arrow.down"), ("Confirm", "↩", "checkmark.circle"),
    ("Close dialog", "Esc", "xmark.circle"),
  ]
  var body: some View {
    let _ = locale
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        SettingsGroup {
          Toggle(isOn: $enabled) { SettingsLabel("Enable ASCEND shortcuts", symbol: "keyboard") }
        }
        SettingsGroup {
          shortcutRows(Array(shortcuts.prefix(4)))
        }
        SettingsGroup {
          shortcutRows(Array(shortcuts.dropFirst(4)))
        }
      }
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func shortcutRows(_ rows: [(String, String, String)]) -> some View {
    ForEach(Array(rows.enumerated()), id: \.element.0) { index, row in
      if index > 0 { RowDivider().padding(.vertical, 12) }
      HStack {
        SettingsLabel(row.0, symbol: row.2)
        Spacer(minLength: 12)
        Text(row.1).font(.system(size: 12, weight: .medium, design: .monospaced))
          .foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
          .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
      }
    }
  }
}

struct DataSettings: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  var body: some View {
    let _ = locale
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        SettingsGroup {
          SettingsLabel("Import & export", symbol: "arrow.up.arrow.down")
            .font(.system(size: 14, weight: .semibold)).padding(.bottom, 16)
          settingsButton("Export JSON…") { store.export(csv: false) }
          RowDivider().padding(.vertical, 12)
          settingsButton("Export CSV…") { store.export(csv: true) }
          RowDivider().padding(.vertical, 12)
          settingsButton("Import…") { store.importFile() }
        }
        SettingsGroup {
          SettingsLabel("Local storage", symbol: "externaldrive")
            .font(.system(size: 14, weight: .semibold)).padding(.bottom, 16)
          settingsButton("Create backup") { store.send("backup") }
          RowDivider().padding(.vertical, 12)
          settingsButton("Show data in Finder") {
            if let path = store.summary?.directory {
              NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
          }
        }
      }
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func settingsButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack {
        SettingsLabel(
          title,
          symbol: [
            "Export JSON…": "curlybraces", "Export CSV…": "tablecells",
            "Import…": "square.and.arrow.down", "Create backup": "externaldrive.badge.timemachine",
            "Show data in Finder": "folder",
          ][title] ?? "doc"
        )
        Spacer(minLength: 12)
        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

struct RulesSettings: View {
  @Environment(\.locale) private var locale
  var body: some View {
    let _ = locale
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        rule(
          "Experience",
          [
            "XP = 10 × minutes / 25 × difficulty × R",
            "XP credits up to 125% of the estimate. R decreases after 180 and 300 minutes of all practice in a day.",
            "Habits earn 1 XP, up to 4 XP per day, and that time counts toward R. A habit establishes a skill after 7 completed days.",
            "Linked milestones share a 40 XP bonus. It is paid when every planned session is done, and never exceeds the practice XP earned on that milestone.",
            "A skill can count time only in the listed apps and sites or pause the timer in those places. An empty list lets the timer run anywhere. ASCEND always counts.",
          ])
        rule(
          "Discipline",
          ["70% commitment completion + 20% consistency + 10% estimate accuracy over 28 days. Finishing within the estimate is accurate; only extra time lowers accuracy.",
           "Plans can reach 100 on their own. A routine then counts for up to 40 points and plans for 60. Four or more items fill the routine share; one item fills a quarter of it.",
           "Routine points come from finished days. Today is not judged yet, and a day you never open is skipped rather than failed."])
        rule(
          "Balance",
          [
            "Weighted completion of weekly goals. Each weight counts up to 10, and exceeding one goal does not compensate for another.",
            "Minutes use credited time. A session or a day counts only after at least 5 credited minutes.",
          ]
        )
        rule(
          "Progress",
          [
            "Mastery confirms each finished quest once. A skill with no quests can be confirmed once, to open what depends on it. Level follows your strongest area; other areas count at a quarter. Earned experience is kept after a break."
          ])
      }
      .padding(22)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func rule(_ title: String, _ lines: [String]) -> some View {
    SettingsGroup {
      VStack(alignment: .leading, spacing: 10) {
        SettingsLabel(
          title,
          symbol: [
            "Experience": "sparkles", "Discipline": "checkmark.seal", "Balance": "scale.3d",
            "Progress": "chart.line.uptrend.xyaxis",
          ][title] ?? "info.circle"
        ).font(.system(size: 14, weight: .semibold))
        ForEach(lines, id: \.self) { line in
          Text(LocalizedStringKey(line)).font(.system(size: 13)).foregroundStyle(.secondary)
            .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }
}
