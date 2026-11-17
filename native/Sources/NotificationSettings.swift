import SwiftUI
import UserNotifications

struct SettingsTabPicker: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var notifications: Notifications
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  @State private var frames: [SettingsTab: CGRect] = [:]

  var body: some View {
    let _ = locale
    if #available(macOS 26, *) {
      glassPicker
    } else {
      systemPicker
    }
  }

  private var systemPicker: some View {
    Picker("Settings", selection: tabBinding) {
      ForEach(SettingsTab.allCases) { tab in
        Label(LocalizedStringKey(tab.rawValue), systemImage: symbol(for: tab))
          .help(LocalizedStringKey(tab.rawValue)).tag(tab)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .fixedSize()
  }

  /// Page content stays put. Only the selection capsule inside this control moves.
  private var tabBinding: Binding<SettingsTab> {
    Binding(
      get: { store.settingsTab },
      set: { tab in
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { store.settingsTab = tab }
      }
    )
  }

  @available(macOS 26, *)
  private var glassPicker: some View {
    LiquidGlassPlate(circular: false, leadingPad: 0, trailingPad: 0, verticalPad: 28) { dragged in
      HStack(spacing: 2) {
        ForEach(SettingsTab.allCases) { tab in
          segment(tab, acceptClick: !dragged)
            .background {
              GeometryReader { geo in
                Color.clear.preference(
                  key: SettingsTabFrames.self,
                  value: [tab: geo.frame(in: .named("settings-tabs"))]
                )
              }
            }
        }
      }
      .coordinateSpace(name: "settings-tabs")
      .background(alignment: .topLeading) {
        if let frame = frames[store.settingsTab], frame.width > 1 {
          Capsule()
            .fill(scheme == .dark ? Color.white.opacity(0.16) : Color.white.opacity(0.62))
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .allowsHitTesting(false)
            .animation(.smooth(duration: 0.32), value: store.settingsTab)
        }
      }
      .padding(.horizontal, 4)
      .onPreferenceChange(SettingsTabFrames.self) { newValue in
        guard !Self.sameFrames(frames, newValue) else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { frames = newValue }
      }
    }
  }

  private func segment(_ tab: SettingsTab, acceptClick: Bool = true) -> some View {
    let selected = store.settingsTab == tab
    return Button {
      if acceptClick { store.settingsTab = tab }
    } label: {
      Label(LocalizedStringKey(tab.rawValue), systemImage: symbol(for: tab))
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .help(LocalizedStringKey(tab.rawValue))
    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
  }

  private func symbol(for tab: SettingsTab) -> String {
    tab == .notifications && notifications.needsAttention ? "exclamationmark.bubble" : tab.symbol
  }

  private static func sameFrames(_ current: [SettingsTab: CGRect], _ next: [SettingsTab: CGRect]) -> Bool {
    guard current.count == next.count else { return false }
    for (tab, rect) in current {
      guard let other = next[tab] else { return false }
      if abs(rect.minX - other.minX) > 0.5 || abs(rect.minY - other.minY) > 0.5
        || abs(rect.width - other.width) > 0.5 || abs(rect.height - other.height) > 0.5
      {
        return false
      }
    }
    return true
  }
}

private struct SettingsTabFrames: PreferenceKey {
  static var defaultValue: [SettingsTab: CGRect] = [:]
  static func reduce(value: inout [SettingsTab: CGRect], nextValue: () -> [SettingsTab: CGRect]) {
    value.merge(nextValue(), uniquingKeysWith: { $1 })
  }
}

struct SettingsLabel: View {
  let title: String
  let symbol: String
  init(_ title: String, symbol: String) {
    self.title = title
    self.symbol = symbol
  }
  var body: some View {
    Label {
      Text(LocalizedStringKey(title))
    } icon: {
      Image(systemName: symbol).foregroundStyle(AppStyle.accent).frame(width: 20)
    }
  }
}

struct NotificationSettings: View {
  @EnvironmentObject var notifications: Notifications
  @Environment(\.locale) private var locale
  private var preferences: NotificationPreferences { notifications.preferences }
  private var enabled: Bool { preferences.enabled }
  private func binding<Value>(_ path: WritableKeyPath<NotificationPreferences, Value>) -> Binding<
    Value
  > {
    Binding(
      get: { notifications.preferences[keyPath: path] },
      set: { notifications.preferences[keyPath: path] = $0 })
  }
  var body: some View {
    let _ = locale
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        SettingsGroup {
          HStack(spacing: 12) {
            Image(
              systemName: notifications.needsAttention
                ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
            )
            .font(.system(size: 23)).foregroundStyle(
              notifications.needsAttention ? AppStyle.amber : AppStyle.mint)
            VStack(alignment: .leading, spacing: 4) {
              Text(notifications.status).font(.system(size: 14, weight: .semibold))
              Text(statusDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if enabled, !notifications.canDeliver {
              if notifications.authorization == .notDetermined {
                Button("Allow…") { notifications.refreshAuthorization(requestIfNeeded: true) }
                  .disabled(notifications.requesting)
              } else {
                Button("Open macOS Settings…") { notifications.openSystemSettings() }
              }
            }
          }
          RowDivider().padding(.vertical, 12)
          Toggle(isOn: Binding(get: { enabled }, set: notifications.setEnabled)) {
            HStack(spacing: 6) {
              SettingsLabel("Enable notifications", symbol: "bell")
              HintButton(
                text: "Daily reminders are scheduled for the next seven days and refreshed while ASCEND runs. Changes apply immediately."
              )
              Spacer(minLength: 0)
            }
          }
          RowDivider().padding(.vertical, 12)
          Toggle(isOn: binding(\.sound)) {
            SettingsLabel("Notification sound", symbol: "speaker.wave.2")
          }
          .disabled(!enabled)
        }
        SettingsGroup {
          Toggle(isOn: binding(\.focus)) {
            HStack(spacing: 6) {
              SettingsLabel("Focus session", symbol: "timer")
              HintButton(
                text: "One alert when your planned session time ends. Pausing cancels it; resuming recalculates it."
              )
              Spacer(minLength: 0)
            }
          }
          RowDivider().padding(.vertical, 12)
          timedToggle("Daily plan", symbol: "checklist", enabled: \.dailyPlan, time: \.planTime)
          RowDivider().padding(.vertical, 12)
          timedToggle(
            "Quest deadlines", symbol: "calendar.badge.exclamationmark", enabled: \.deadlines,
            time: \.deadlineTime)
          RowDivider().padding(.vertical, 12)
          timedToggle(
            "Evening reflection", symbol: "book.closed", enabled: \.dailyReview, time: \.reviewTime)
        }.disabled(!enabled)
        SettingsGroup {
          Toggle(isOn: binding(\.quietHours)) {
            HStack(spacing: 6) {
              SettingsLabel("Quiet hours", symbol: "moon.zzz")
              HintButton(
                text: "Reminders during quiet hours are skipped. Test notifications are sent on request."
              )
              Spacer(minLength: 0)
            }
          }
          if preferences.quietHours {
            HStack(spacing: 12) {
              SettingsLabel("From", symbol: "moon")
              timePicker(\.quietStart)
              Spacer()
              SettingsLabel("Until", symbol: "sunrise")
              timePicker(\.quietEnd)
            }.padding(.top, 12)
          }
        }.disabled(!enabled)
        SettingsGroup {
          VStack(alignment: .leading, spacing: 0) {
            Button {
              notifications.sendTest()
            } label: {
              HStack {
                SettingsLabel(
                  notifications.testing ? "Sending…" : "Send test notification",
                  symbol: "paperplane")
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(
                  .secondary)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
              .disabled(!enabled || !notifications.canDeliver || notifications.testing)
            RowDivider().padding(.vertical, 12)
            Button {
              notifications.refreshAuthorization()
            } label: {
              HStack {
                SettingsLabel("Check permission", symbol: "arrow.clockwise")
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(
                  .secondary)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }
      }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
    }
    .onAppear { notifications.refreshAuthorization() }
    .alert(
      "Unable to update notifications",
      isPresented: Binding(
        get: { notifications.error != nil }, set: { if !$0 { notifications.clearError() } })
    ) {
      Button("OK") { notifications.clearError() }
    } message: {
      Text(notifications.error ?? "")
    }
  }
  private var statusDetail: LocalizedStringKey {
    if !enabled { return "Turn on the reminders you want to receive." }
    if notifications.requesting { return "Respond to the macOS notification permission prompt." }
    if notifications.authorization == .denied {
      return "Allow ASCEND in System Settings → Notifications."
    }
    if !notifications.canDeliver { return "macOS permission is required to deliver reminders." }
    if !notifications.bannersEnabled {
      return "Delivered to Notification Center. Banners are off in macOS."
    }
    return "macOS Focus settings can silence notification banners."
  }
  private func timedToggle(
    _ title: String, symbol: String,
    enabled path: WritableKeyPath<NotificationPreferences, Bool>,
    time: WritableKeyPath<NotificationPreferences, Int>
  ) -> some View {
    HStack(spacing: 16) {
      SettingsLabel(title, symbol: symbol)
        .frame(maxWidth: .infinity, alignment: .leading)
      timePicker(time).disabled(!preferences[keyPath: path])
      Toggle(LocalizedStringKey(title), isOn: binding(path))
        .labelsHidden().toggleStyle(.switch).fixedSize()
    }
  }
  private func timePicker(_ path: WritableKeyPath<NotificationPreferences, Int>) -> some View {
    let calendar = NotificationPlan.calendar()
    return DatePicker(
      "Time",
      selection: Binding(
        get: {
          let minute = notifications.preferences[keyPath: path]
          return calendar.date(
            bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        },
        set: { date in
          notifications.preferences[keyPath: path] =
            calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
        }), displayedComponents: .hourAndMinute
    )
    .labelsHidden().datePickerStyle(.field).fixedSize()
  }
}
