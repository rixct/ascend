import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  static weak var store: Store?
  static weak var notifications: Notifications?
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    guard UserDefaults.standard.object(forKey: "runInBackground") != nil else { return false }
    return !UserDefaults.standard.bool(forKey: "runInBackground")
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let store = Self.store else { return .terminateNow }
    DispatchQueue.main.async {
      store.presence.end()
      let finish = { store.prepareToTerminate { sender.reply(toApplicationShouldTerminate: true) } }
      if let notifications = Self.notifications {
        notifications.prepareToTerminate(completion: finish)
      } else {
        finish()
      }
    }
    return .terminateLater
  }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.applicationIconImage = AppMark.dock
  }
  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { Self.store?.shutdown() }
  }
}

@main struct ASCENDApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var store = Store()
  @StateObject private var notifications = Notifications()
  @StateObject private var systemAppearance = SystemAppearance()
  @AppStorage("appearance") private var appearance = "system"
  @AppStorage("style") private var style = "minimal"
  @AppStorage("language") private var language = "system"
  private var colorScheme: ColorScheme { systemAppearance.resolved(appearance) }
  var body: some Scene {
    Window("ASCEND", id: "main") {
      RootView().environmentObject(store).environmentObject(notifications).environmentObject(store.presence)
        .preferredColorScheme(colorScheme)
        .toggleStyle(TrailingSwitchStyle())
        .onAppear {
          AppDelegate.store = store
          AppDelegate.notifications = notifications
        }
        .tint(colorScheme == .light && style == "colorful" ? AppStyle.choice : AppStyle.accent)
        .environment(\.locale, AppLanguage.resolved(language).locale)
    }
    .defaultSize(width: 1120, height: 760)
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified)
    .commands {
      CommandGroup(after: .newItem) {
        Button(L("New quest…")) { store.newQuest() }
        Button(L("New skill…")) { store.sheet = .skill }
      }
    }
    Settings {
      SettingsView().environmentObject(store).environmentObject(notifications).environmentObject(store.presence).toolbar {
        ToolbarItem(placement: .principal) {
          SettingsTabPicker().environmentObject(store).environmentObject(notifications)
        }
      }.tint(
        colorScheme == .light && style == "colorful" ? AppStyle.choice : AppStyle.accent
      )
      .toggleStyle(TrailingSwitchStyle())
      .preferredColorScheme(colorScheme).environment(
        \.locale, AppLanguage.resolved(language).locale
      ).frame(width: 680, height: 700)
    }
    MenuBarExtra {
      TrayMenu().environmentObject(store).environment(
        \.locale, AppLanguage.resolved(language).locale)
    } label: {
      MenuBarStatus(active: store.state?.active)
    }
    .menuBarExtraStyle(.menu)
  }
}

private struct MenuBarStatus: View {
  let active: ActiveSession?
  var body: some View {
    HStack(spacing: 5) {
      Image(nsImage: AppMark.menuBar)
        .renderingMode(.original)
        .frame(width: 18, height: 18)
      if let active {
        Text(clock(active.elapsed_seconds))
          .font(.system(size: 13, weight: .medium).monospacedDigit())
      }
    }
    .accessibilityLabel(
      active.map { "\(L("Session")) \(clock($0.elapsed_seconds))" } ?? "ASCEND")
  }
}

enum AppMark {
  static let menuBar = image(points: 18)
  static let dock = image(points: 512)

  static func image(points: CGFloat) -> NSImage {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    let pixels = max(1, Int((points * scale).rounded()))
    let fallback = NSImage(size: NSSize(width: points, height: points))
    guard
      let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
    else { return fallback }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    draw(edge: CGFloat(pixels))
    NSGraphicsContext.restoreGraphicsState()
    let image = NSImage(size: NSSize(width: points, height: points))
    image.addRepresentation(bitmap)
    image.isTemplate = false
    return image
  }

  static func draw(edge w: CGFloat) {
    let margin = w * 100 / 1024
    let side = w * 824 / 1024
    let bounds = NSRect(x: margin, y: margin, width: side, height: side)
    let radius = side * 185 / 824
    let shape = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
    NSColor(red: 0.11, green: 0.13, blue: 0.12, alpha: 1).setFill()
    shape.fill()
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
      NSPoint(x: margin + side * x, y: margin + side * y)
    }
    let mark = NSBezierPath()
    mark.move(to: pt(0.25, 0.348))
    mark.line(to: pt(0.50, 0.696))
    mark.line(to: pt(0.75, 0.348))
    mark.lineWidth = side * 0.096
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round
    NSColor(red: 0.95, green: 0.97, blue: 0.95, alpha: 1).setStroke()
    mark.stroke()
  }
}

struct TrayMenu: View {
  @Environment(\.locale) private var locale
  @EnvironmentObject var store: Store
  @Environment(\.openWindow) private var openWindow
  @State private var confirmReset = false
  @State private var confirmCancel = false
  var body: some View {
    let _ = locale
    if let active = store.state?.active {
      Text(store.state?.quest(active.quest_id)?.title ?? L("Session"))
      Text(clock(active.elapsed_seconds))
      Button(L(active.running ? "Pause" : "Resume")) { store.send("pause") }
      Button("Cancel session") { confirmCancel = true }
      .confirmationDialog(
        "Cancel this session?", isPresented: $confirmCancel, titleVisibility: .visible
      ) {
        Button("Cancel session", role: .destructive) {
          store.send("discard_session", ["id": active.id])
        }
        Button("Keep session", role: .cancel) {}
      } message: {
        Text("This session's time and notes will not be saved.")
      }
      Button("Reset timer") { confirmReset = true }
      .confirmationDialog("Reset the timer?", isPresented: $confirmReset, titleVisibility: .visible) {
        Button("Reset timer", role: .destructive) { store.send("reset_timer") }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("Counted time for this session returns to zero.")
      }
      Button("Finish session…") {
        store.finish()
        showMain()
      }
    }
    Divider()
    Button("Open ASCEND") { showMain() }
    Button("New quest…") {
      store.newQuest()
      showMain()
    }
    Divider()
    Button("Quit ASCEND") { NSApp.terminate(nil) }
  }
  private func showMain() {
    openWindow(id: "main")
    NSApp.activate(ignoringOtherApps: true)
  }
}

private enum WindowTool: String, Identifiable {
  case newQuest, newSkill, deleteSkills, cancelEdit, selectSkills, newTarget, newEntry, focus,
    settings, skillTree, milestones
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .newQuest, .newSkill, .newTarget: "plus"
    case .deleteSkills: "trash"
    case .cancelEdit: "xmark"
    case .selectSkills: "pencil"
    case .newEntry: "square.and.pencil"
    case .focus: "viewfinder"
    case .settings: "gearshape"
    case .skillTree: "point.3.filled.connected.trianglepath.dotted"
    case .milestones: "checkmark.seal"
    }
  }
  var help: String {
    switch self {
    case .newQuest: "New quest"
    case .newSkill: "New skill"
    case .deleteSkills: "Delete skill"
    case .cancelEdit: "Cancel"
    case .selectSkills: "Select skills"
    case .newTarget: "Weekly goal"
    case .newEntry: "New entry"
    case .focus: "Focus mode"
    case .settings: "Settings"
    case .skillTree: "Skill tree"
    case .milestones: "Milestones"
    }
  }
}

@MainActor private func windowTools(_ store: Store) -> [WindowTool] {
  switch store.page ?? .dashboard {
  case .dashboard: [.newQuest, .focus]
  case .quests: [.newQuest, .focus]
  case .skills:
    store.skillEditing ? [.deleteSkills, .cancelEdit] : [.skillTree, .newSkill, .selectSkills]
  case .balance: [.newTarget, .focus]
  case .journal: [.newEntry, .focus]
  case .character: [.milestones, .focus, .settings]
  case .analytics: [.focus]
  case .settings: []
  case .skillTree: store.questTreeSkill == nil ? [.newSkill] : [.newQuest]
  }
}

private struct WindowToolbar: View {
  @EnvironmentObject var store: Store
  var body: some View {
    if #available(macOS 26, *) {
      LiquidWindowToolbar()
    } else {
      HStack(spacing: 8) {
        ForEach(windowTools(store)) { tool in
          WindowToolButton(tool: tool)
        }
      }
    }
  }
}

@available(macOS 26, *)
private struct GlassBackButton: View {
  let action: () -> Void
  var body: some View {
    LiquidGlassPlate(circular: true, leadingPad: 4, trailingPad: 28) { dragged in
      Image(systemName: "chevron.left")
        .font(.system(size: 15, weight: .medium))
        .frame(width: 36, height: 36)
        .background(Color.primary.opacity(0.001))
        .contentShape(Circle())
        .onTapGesture { if !dragged { action() } }
        .help(LocalizedStringKey("Back"))
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(LocalizedStringKey("Back"))
    }
  }
}

struct GlassTextButton: View {
  let title: String
  var enabled: Bool = true
  var leadingPad: CGFloat = 28
  var trailingPad: CGFloat = 8
  var verticalPad: CGFloat = 28
  let action: () -> Void
  var body: some View {
    if #available(macOS 26, *) {
      GlassTextPlate(
        title: title, enabled: enabled, leadingPad: leadingPad, trailingPad: trailingPad,
        verticalPad: verticalPad, action: action)
    } else {
      Button(action: action) { Text(LocalizedStringKey(title)) }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!enabled)
    }
  }
}

@available(macOS 26, *)
private struct GlassTextPlate: View {
  let title: String
  var enabled: Bool
  var leadingPad: CGFloat
  var trailingPad: CGFloat
  var verticalPad: CGFloat
  let action: () -> Void
  var body: some View {
    LiquidGlassPlate(
      circular: false, leadingPad: leadingPad, trailingPad: trailingPad, verticalPad: verticalPad
    ) { dragged in
      Text(LocalizedStringKey(title))
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(Color.primary.opacity(0.001))
        .contentShape(Capsule())
        .onTapGesture { if enabled, !dragged { action() } }
        .opacity(enabled ? 1 : 0.45)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(LocalizedStringKey(title))
    }
    .allowsHitTesting(enabled)
  }
}

private struct HideToolbarTitle: ViewModifier {
  var hidden: Bool
  @ViewBuilder func body(content: Content) -> some View {
    if hidden {
      if #available(macOS 15, *) {
        content.toolbar(removing: .title)
      } else {
        content
      }
    } else {
      content
    }
  }
}

@available(macOS 26, *)
private struct LiquidWindowToolbar: View {
  @EnvironmentObject var store: Store
  private var tools: [WindowTool] { windowTools(store) }
  var body: some View {
    if tools.isEmpty {
      EmptyView()
    } else {
      glass
    }
  }
  private var glass: some View {
    LiquidGlassPlate(circular: tools.count <= 1, trailingPad: 8) { dragged in
      HStack(spacing: 0) {
        ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
          WindowToolButton(
            tool: tool,
            acceptClick: !dragged,
            leading: tools.count > 1 && index == 0 ? 4 : 0,
            trailing: tools.count > 1 && index == tools.count - 1 ? 4 : 0,
            circular: tools.count == 1
          )
        }
      }
    }
    .animation(.smooth(duration: 0.35), value: tools.map(\.id))
  }
}

@available(macOS 26, *)
struct LiquidGlassPlate<Content: View>: View {
  var circular: Bool
  var leadingPad: CGFloat = 28
  var trailingPad: CGFloat = 0
  var verticalPad: CGFloat = 28
  @ViewBuilder var content: (Bool) -> Content
  @State private var stretch = CGSize.zero
  @State private var lift: CGFloat = 0
  @State private var touch = CGPoint.zero
  @State private var highlight: CGFloat = 0
  @State private var glassSize = CGSize(width: 36, height: 36)
  @State private var dragged = false
  private var hitShape: AnyShape {
    circular ? AnyShape(Circle()) : AnyShape(Capsule())
  }
  private static var liftOn: Animation {
    .spring(Spring(mass: 1.36, stiffness: 568, damping: 39.7))
  }
  private static var liftOff: Animation {
    .spring(Spring(mass: 2, stiffness: 460, damping: 21.8))
  }
  var body: some View {
    let shape = glassTransform(size: glassSize, stretch: stretch)
    let cluster = content(dragged)
      .frame(width: circular ? 36 : nil, height: 36)
      .fixedSize()
      .background { hitShape.fill(Color.primary.opacity(0.001)) }
      .contentShape(hitShape)
      .overlay {
        Circle()
          .fill(
            RadialGradient(
              colors: [Color.white.opacity(0.5), Color.white.opacity(0)],
              center: .center, startRadius: 0, endRadius: 150
            )
          )
          .frame(width: 300, height: 300)
          .position(touch)
          .opacity(highlight * 0.1)
          .allowsHitTesting(false)
      }
      .simultaneousGesture(pullGesture)
    Group {
      if circular {
        cluster.glassEffect(.regular.interactive(), in: Circle())
      } else {
        cluster.glassEffect(.regular.interactive(), in: Capsule())
      }
    }
    .onGeometryChange(for: CGSize.self, of: \.size) { glassSize = $0 }
    .scaleEffect(x: shape.sx, y: shape.sy)
    .offset(x: shape.tx, y: shape.ty)
    .padding(.leading, leadingPad)
    .padding(.trailing, trailingPad)
    .padding(.vertical, verticalPad)
  }
  private var pullGesture: some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        let dx = value.translation.width
        let dy = value.translation.height
        if hypot(dx, dy) > 6 { dragged = true }
        touch = value.location
        if lift == 0 {
          withAnimation(Self.liftOn) { lift = 1 }
          withAnimation(.easeOut(duration: 0.12)) { highlight = 1 }
        } else if hypot(dx, dy) > 1 {
          var transaction = Transaction()
          transaction.disablesAnimations = true
          withTransaction(transaction) { lift = 1 }
        }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
          stretch = CGSize(width: dx, height: dy)
        }
      }
      .onEnded { _ in
        withAnimation(Self.liftOff) {
          lift = 0
          stretch = .zero
        }
        withAnimation(.easeInOut(duration: 0.22)) { highlight = 0 }
        DispatchQueue.main.async { dragged = false }
      }
  }
}

/// Telegram `TouchEffect` drag curve, without the press scale that grows the control.
private func glassTransform(size: CGSize, stretch: CGSize) -> (
  sx: CGFloat, sy: CGFloat, tx: CGFloat, ty: CGFloat
) {
  let viewWidth = max(1, size.width)
  let viewHeight = max(1, size.height)
  let aspectRatio = viewWidth / viewHeight
  let adjustedX = stretch.width / aspectRatio
  let length = hypot(adjustedX, stretch.height)
  guard length > 0.001 else { return (1, 1, 0, 0) }
  let normalX = adjustedX / length
  let normalY = stretch.height / length
  let k = -1 / ((length / viewHeight) / (5 * aspectRatio) + 1) + 1
  let additionalMaxScale = (viewHeight + 16 / aspectRatio) / viewHeight - 1
  let t = additionalMaxScale * k * aspectRatio
  let tx = normalX * 24 * k
  let ty = normalY * 24 * k
  if abs(normalX) > abs(normalY) {
    let diff = abs(normalX) - abs(normalY)
    return (1 + t * diff, 1 / (1 + t * diff), tx, ty)
  } else {
    let diff = abs(normalY) - abs(normalX)
    return (1 / (1 + t * diff), 1 + t * diff, tx, ty)
  }
}

private struct WindowToolButton: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var notifications: Notifications
  let tool: WindowTool
  var acceptClick = true
  var leading: CGFloat = 0
  var trailing: CGFloat = 0
  var circular = false
  private var disabled: Bool { tool == .deleteSkills && store.skillSelection.isEmpty }
  var body: some View {
    Image(systemName: tool.symbol)
      .font(.system(size: 15, weight: .medium))
      .frame(width: 36, height: 36)
      .padding(.leading, leading)
      .padding(.trailing, trailing)
      .background(Color.primary.opacity(0.001))
      .contentShape(circular ? AnyShape(Circle()) : AnyShape(Rectangle()))
      .onTapGesture {
        if acceptClick, !disabled { run() }
      }
      .overlay(alignment: .topTrailing) {
        if tool == .settings, notifications.needsAttention {
          Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9, weight: .semibold))
            .foregroundStyle(AppStyle.amber).padding(3).allowsHitTesting(false)
        }
      }
      .help(LocalizedStringKey(tool.help))
      .accessibilityAddTraits(.isButton)
      .accessibilityLabel(LocalizedStringKey(tool.help))
      .accessibilityAction { if acceptClick, !disabled { run() } }
      .opacity(disabled ? 0.4 : 1)
      .allowsHitTesting(!disabled)
  }
  private func run() {
    switch tool {
    case .newQuest: store.newQuest()
    case .newSkill: store.sheet = .skill
    case .deleteSkills: store.confirmSkillDelete = true
    case .cancelEdit: store.endSkillEditing()
    case .selectSkills: store.skillEditing = true
    case .newTarget: store.sheet = .target
    case .newEntry: store.sheet = .journal
    case .focus: store.focusMode = true
    case .settings: store.openSettings()
    case .skillTree: store.navigate(.skillTree)
    case .milestones: store.sheet = .milestones
    }
  }
}

private struct SidebarAccount: View {
  let name: String
  let avatar: String?
  let selected: Bool
  let action: () -> Void
  var body: some View {
    HStack(spacing: 8) {
      ProfileAvatar(encodedImage: avatar, size: 32, circular: true)
      Text(name.isEmpty ? L("Character") : name)
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
        .foregroundStyle(selected ? Color.white : Color.primary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(selected ? Color.accentColor : Color.primary.opacity(0.001))
    }
    .padding(.horizontal, 10)
    .padding(.bottom, 12)
    .contentShape(Rectangle())
    .onTapGesture(perform: action)
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(name.isEmpty ? L("Character") : name)
  }
}

struct RootView: View {
  @EnvironmentObject var notifications: Notifications
  @Environment(\.openWindow) private var openWindow
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  @AppStorage("style") private var style = "minimal"
  @EnvironmentObject var store: Store
  var body: some View {
    let _ = locale
    Group {
      if let state = store.state, let summary = store.summary {
        if !state.settings.onboarded {
          OnboardingView()
        } else if store.focusMode {
          FocusView(state: state, summary: summary)
        } else {
          NavigationSplitView {
            List(Page.menu, selection: $store.page) { page in
              Label(LocalizedStringKey(page.rawValue), systemImage: page.symbol).font(
                .system(size: 13, weight: .medium)
              ).padding(.vertical, 4).tag(page)
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
              SidebarAccount(
                name: state.settings.name, avatar: state.settings.avatar,
                selected: store.page == .character
              ) {
                store.endSkillEditing()
                store.page = .character
              }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 204, max: 250)
            .onChange(of: store.page) { page in
              if page != .skills { store.endSkillEditing() }
              if page != .skillTree && page != .settings { store.questTreeSkill = nil }
            }
          } detail: {
            detailPage(store.page ?? .dashboard, state: state, summary: summary)
              .background {
                SettingsBackSwipe(enabled: store.page == .settings) {
                  goBack()
                }
              }
              .navigationTitle(
                store.page == .settings
                  ? ""
                  : L(
                    store.page == .skillTree && store.questTreeSkill != nil
                      ? "Quest tree" : (store.page ?? .dashboard).rawValue)
              )
              .modifier(HideToolbarTitle(hidden: store.page == .settings))
              .toolbar {
                if store.page == .settings || store.page == .skillTree {
                  if #available(macOS 26, *) {
                    ToolbarItem(placement: .navigation) {
                      GlassBackButton(action: goBack)
                    }
                    .sharedBackgroundVisibility(.hidden)
                  } else {
                    ToolbarItem(placement: .navigation) {
                      Button(action: goBack) {
                        Image(systemName: "chevron.left")
                      }
                      .help(LocalizedStringKey("Back"))
                    }
                  }
                  if store.page == .settings {
                    if #available(macOS 26, *) {
                      ToolbarItem(placement: .principal) { SettingsTabPicker() }
                        .sharedBackgroundVisibility(.hidden)
                    } else {
                      ToolbarItem(placement: .principal) { SettingsTabPicker() }
                    }
                  }
                }
                if !windowTools(store).isEmpty {
                  if #available(macOS 26, *) {
                    ToolbarItem(placement: .primaryAction) {
                      WindowToolbar()
                    }
                    .sharedBackgroundVisibility(.hidden)
                  } else {
                    ToolbarItem(placement: .primaryAction) {
                      WindowToolbar()
                    }
                  }
                }
              }
          }
        }
      } else {
        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .onAppear {
      let action = openWindow
      notifications.openMainWindow = {
        action(id: "main")
        NSApp.activate(ignoringOtherApps: true)
      }
      notifications.start(store: store)
    }
    .frame(minWidth: 860, minHeight: 580)
    .background(AppChrome.canvas(style: style, scheme: scheme).ignoresSafeArea())
    .onAppear { paintWindow() }
    .onChange(of: style) { _ in paintWindow() }
    .onChange(of: scheme) { _ in paintWindow() }
    .sheet(item: $store.sheet) {
      SheetView(sheet: $0).environmentObject(store).environment(\.locale, locale)
    }
    .alert(
      L("Unable to complete the action"),
      isPresented: Binding(
        get: { store.error != nil && store.sheet == nil }, set: { if !$0 { store.error = nil } })
    ) {
      Button(L("OK")) { store.error = nil }
    } message: {
      Text(englishText(store.error ?? ""))
    }
    .confirmationDialog(
      L("Replace this profile?"),
      isPresented: Binding(get: { store.preview != nil }, set: { if !$0 { store.cancelImport() } }),
      titleVisibility: .visible
    ) {
      Button(L("Replace"), role: .destructive) {
        store.send("confirm_import")
        store.preview = nil
      }
    } message: {
      if let p = store.preview {
        Text(
          L(
            "%@ — skills: %d, quests: %d, sessions: %d. Your current data will be backed up first.",
            p.name, p.skills, p.quests, p.sessions)
        )
      }
    }
  }

  private func paintWindow() {
    let color: NSColor =
      style == "colorful" && scheme != .dark
      ? NSColor(srgbRed: 0.82, green: 0.875, blue: 0.83, alpha: 1)
      : .windowBackgroundColor
    for window in NSApp.windows where window.title == "ASCEND" {
      window.backgroundColor = color
    }
  }
  private func goBack() {
    if store.page == .skillTree {
      if store.questTreeSkill != nil { store.questTreeSkill = nil } else { store.navigate(.skills) }
    } else {
      store.closeSettings()
    }
  }

  @ViewBuilder private func detailPage(_ page: Page, state: GameState, summary: Summary)
    -> some View
  {
    switch page {
    case .dashboard: DashboardView(state: state, summary: summary)
    case .character: CharacterView(state: state, summary: summary)
    case .skills: SkillsView(state: state, summary: summary)
    case .skillTree: SkillTreeView(state: state, summary: summary)
    case .quests: QuestsView(state: state, summary: summary)
    case .balance: BalanceView(state: state, summary: summary)
    case .analytics: AnalyticsView(state: state, summary: summary)
    case .journal: JournalView(state: state)
    case .settings: SettingsView()
    }
  }
}

private struct SettingsBackSwipe: NSViewRepresentable {
  var enabled: Bool
  var onBack: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(onBack: onBack)
  }
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    context.coordinator.view = view
    context.coordinator.start()
    return view
  }
  func updateNSView(_ nsView: NSView, context: Context) {
    context.coordinator.enabled = enabled
    context.coordinator.onBack = onBack
  }
  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  final class Coordinator {
    var enabled = false
    var onBack: () -> Void
    var monitor: Any?
    weak var view: NSView?
    var active = false
    var ignored = false
    var travel: CGFloat = 0
    init(onBack: @escaping () -> Void) {
      self.onBack = onBack
    }
    func start() {
      guard monitor == nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
        self?.handle(event) ?? event
      }
    }
    func stop() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }
    deinit { stop() }
    func handle(_ event: NSEvent) -> NSEvent? {
      guard let window = view?.window, event.window === window, window.attachedSheet == nil,
        enabled, event.hasPreciseScrollingDeltas
      else { return event }
      let dx = event.scrollingDeltaX
      let dy = event.scrollingDeltaY
      if event.phase == .began {
        active = false
        ignored = false
        travel = 0
      }
      if ignored { return event }
      if event.phase == .changed {
        if !active {
          if abs(dx) < 0.8 && abs(dy) < 0.8 { return event }
          if dx > 1, abs(dx) > abs(dy) * 1.2 {
            active = true
          } else {
            ignored = true
            return event
          }
        }
        travel = max(0, travel + dx)
        return nil
      }
      if event.phase == .ended || event.phase == .cancelled {
        if active {
          let commit = event.phase == .ended && travel > 90
          active = false
          if commit { onBack() }
          return nil
        }
      }
      if active, event.momentumPhase != [] { return nil }
      return event
    }
  }
}

struct OnboardingView: View {
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  @AppStorage("style") private var style = "minimal"
  @EnvironmentObject var store: Store
  @State private var routineRows = RoutineDraft.blank
  @State private var step = 1
  @State private var name = ""
  @State private var avatar: String?
  @State private var imageError: String?
  private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
  var body: some View {
    let _ = locale
    ZStack {
      AppChrome.canvas(style: style, scheme: scheme)
      Group {
        if step == 1 {
          profileStep
        } else if step == 2 {
          setupStep
        } else {
          routineStep
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(AppChrome.canvas(style: style, scheme: scheme).ignoresSafeArea())
    .alert(
      "Unable to open photo",
      isPresented: Binding(
        get: { imageError != nil }, set: { if !$0 { imageError = nil } })
    ) {
      Button("OK") { imageError = nil }
    } message: {
      Text(imageError ?? "")
    }
  }
  private var profileStep: some View {
    OnboardingPanel(width: 440) {
      VStack(spacing: 22) {
        Text("Create your profile").font(.system(size: 20, weight: .semibold))
        VStack(spacing: 8) {
          Button(action: pickPhoto) {
            ZStack(alignment: .bottomTrailing) {
              ProfileAvatar(encodedImage: avatar, size: 88)
              Image(systemName: "camera.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(AppStyle.choice, in: Circle())
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .offset(x: 4, y: 4)
            }
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Profile photo")
          HintButton(text: "Photo is optional")
          if avatar != nil {
            Button("Remove photo") { avatar = nil }
              .buttonStyle(.borderless)
              .font(.system(size: 12))
              .foregroundStyle(.secondary)
          }
        }
        TextField("Your name", text: $name)
          .textFieldStyle(.roundedBorder)
          .controlSize(.large)
          .accessibilityLabel("Name")
          .onSubmit { if !trimmedName.isEmpty { step = 2 } }
        HStack {
          Spacer()
          Button("Continue") { step = 2 }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(trimmedName.isEmpty)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }
  private var setupStep: some View {
    OnboardingPanel(width: 580) {
      VStack(spacing: 26) {
        HStack(spacing: 6) {
          Text("Appearance").font(.system(size: 18, weight: .semibold))
          HintButton(text: "You can change the theme later in Settings → General.")
        }
        ThemeChooser()
        HStack {
          Button("Back") { step = 1 }
            .buttonStyle(.borderless)
          Spacer()
          Button("Continue") { step = 3 }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(trimmedName.isEmpty || store.busy)
            .keyboardShortcut(.defaultAction)
        }
      }
    }
  }
  private var routineStep: some View {
    OnboardingPanel(width: 580) {
      VStack(alignment: .leading, spacing: 18) {
        HStack(spacing: 6) {
          Text("Create your daily routine").font(.system(size: 21, weight: .semibold))
          HintButton(
            text: "Choose a few real actions. A routine adds up to 40 discipline points from finished days, and one item counts less than a full list."
          )
        }
        ScrollView {
          RoutineDraftList(rows: $routineRows).padding(2)
        }.frame(height: min(260, CGFloat(routineRows.count) * 44 + 36))
        if !RoutineDraft.titles(routineRows).isEmpty && !RoutineDraft.valid(routineRows) {
          Text("Use unique names, up to 100 characters each.").font(.system(size: 11)).foregroundStyle(AppStyle.amber)
        }
        HStack {
          Button("Back") { step = 2 }.buttonStyle(.borderless)
          Spacer()
          Button("Set up later") { finish(withRoutine: false) }.disabled(store.busy)
          Button("Get started") { finish(withRoutine: true) }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(!RoutineDraft.valid(routineRows) || store.busy).keyboardShortcut(.defaultAction)
        }
      }.disabled(store.busy)
    }
  }
  private func pickPhoto() {
    AvatarPicker.choose { result in
      switch result {
      case .success(let selected): if let selected { avatar = selected }
      case .failure(let error): imageError = error.localizedDescription
      }
    }
  }
  private func finish(withRoutine: Bool) {
    guard !trimmedName.isEmpty, !withRoutine || RoutineDraft.valid(routineRows) else { return }
    let chosenAvatar = avatar
    let chosenName = trimmedName
    var values: [String: Any] = ["name": chosenName, "minutes": 90, "starter": false]
    if withRoutine { values["routine_items"] = RoutineDraft.titles(routineRows) }
    store.send("onboard", values) {
      guard let chosenAvatar else { return }
      store.send(
        "settings",
        ["name": chosenName, "avatar": chosenAvatar, "minutes": 90, "growth": 10])
    }
  }
}

private struct OnboardingPanel<Content: View>: View {
  @Environment(\.colorScheme) private var scheme
  @AppStorage("style") private var style = "minimal"
  var width: CGFloat
  @ViewBuilder var content: () -> Content
  private var fill: Color {
    if style == "colorful", scheme != .dark {
      return Color(red: 0.905, green: 0.933, blue: 0.906)
    }
    return scheme == .dark ? Color(white: 0.18) : Color.white
  }
  var body: some View {
    content()
      .padding(28)
      .frame(width: width)
      .background {
        RoundedRectangle(cornerRadius: 28, style: .continuous)
          .fill(fill)
      }
  }
}
