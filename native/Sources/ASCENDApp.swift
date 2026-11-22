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
        .onOpenURL { notifications.openRoute($0) }
        .tint(colorScheme == .light && style == "colorful" ? AppStyle.choice : AppStyle.accent)
        .environment(\.locale, AppLanguage.resolved(language).locale)
    }
    .defaultSize(width: 1120, height: 760)
    .windowStyle(.hiddenTitleBar)
    .commands {
      CommandGroup(after: .newItem) {
        Button(L("New quest…")) { store.newQuest() }
        Button(L("New skill…")) { store.sheet = .skill }
        Button(L("New journal entry…")) { store.sheet = .journal }
          .disabled(store.state?.settings.onboarded != true || store.sheet != nil)
      }
      WorkspaceSearchCommands(store: store)
    }
    Settings {
      SettingsView().environmentObject(store).environmentObject(notifications).environmentObject(store.presence)
        .tint(colorScheme == .light && style == "colorful" ? AppStyle.choice : AppStyle.accent)
        .toggleStyle(TrailingSwitchStyle())
        .preferredColorScheme(colorScheme)
        .environment(\.locale, AppLanguage.resolved(language).locale)
        .frame(width: 680, height: 700)
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

private struct WorkspaceSearchKey: FocusedValueKey {
  typealias Value = () -> Void
}

private extension FocusedValues {
  var workspaceSearch: (() -> Void)? {
    get { self[WorkspaceSearchKey.self] }
    set { self[WorkspaceSearchKey.self] = newValue }
  }
}

private struct WorkspaceSearchCommands: Commands {
  @FocusedValue(\.workspaceSearch) private var search
  @AppStorage("shortcutsEnabled") private var shortcutsEnabled = true
  @ObservedObject var store: Store

  var body: some Commands {
    CommandGroup(after: .textEditing) {
      Button(L("Search")) { search?() }
        .keyboardShortcut("f", modifiers: .command)
        .disabled(!shortcutsEnabled || search == nil || store.sheet != nil
          || store.preview != nil || store.error != nil)
    }
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
  case newQuest, newSkill, deleteSkills, cancelEdit, selectSkills, newTarget, focus,
    settings, skillTree, milestones
  var id: String { rawValue }
  var symbol: String {
    switch self {
    case .newQuest, .newSkill, .newTarget: "plus"
    case .deleteSkills: "trash"
    case .cancelEdit: "xmark"
    case .selectSkills: "pencil"
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
  case .journal: [.focus]
  case .character: [.milestones, .focus, .settings]
  case .analytics: [.focus]
  case .settings: []
  case .skillTree: store.questTreeSkill == nil ? [.newSkill] : [.newQuest]
  }
}

private struct WindowToolbar: View {
  @EnvironmentObject var store: Store

  var body: some View {
    let tools = windowTools(store)
    if #available(macOS 26, *) {
      LiquidWindowToolbar(tools: tools)
    } else {
      HStack(spacing: 8) {
        ForEach(tools) { tool in
          WindowToolButton(tool: tool)
        }
      }
    }
  }
}

@available(macOS 26, *)
struct GlassIconButton: View {
  let symbol: String
  let title: LocalizedStringKey
  let action: () -> Void

  var body: some View {
    LiquidGlassPlate(circular: true, leadingPad: 0, verticalPad: 0) { dragged in
      Button {
        if !dragged { action() }
      } label: {
        Image(systemName: symbol)
          .font(.system(size: 15, weight: .medium))
          .frame(width: WorkspaceHeaderLayout.controlSize, height: WorkspaceHeaderLayout.controlSize)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help(title)
      .accessibilityLabel(title)
    }
  }
}

@available(macOS 26, *)
private struct LiquidWindowToolbar: View {
  let tools: [WindowTool]
  var body: some View {
    if tools.isEmpty {
      EmptyView()
    } else {
      glass
    }
  }
  private var glass: some View {
    LiquidGlassPlate(circular: tools.count <= 1, leadingPad: 0, verticalPad: 0) { dragged in
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
  var allowsDrag = true
  @ViewBuilder var content: (Bool) -> Content
  @State private var stretch = CGSize.zero
  @State private var lift: CGFloat = 0
  @State private var touch = CGPoint.zero
  @State private var highlight: CGFloat = 0
  @State private var glassSize = CGSize(
    width: WorkspaceHeaderLayout.controlSize, height: WorkspaceHeaderLayout.controlSize)
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
    let side = WorkspaceHeaderLayout.controlSize
    let cluster = content(dragged)
      .frame(width: circular ? side : nil, height: side)
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
      .simultaneousGesture(pullGesture, including: allowsDrag ? .all : .subviews)
    Group {
      if circular {
        cluster.glassEffect(.regular.interactive(), in: Circle())
      } else {
        cluster.glassEffect(.regular.interactive(), in: Capsule())
      }
    }
    .onGeometryChange(for: CGSize.self, of: \.size) { glassSize = $0 }
    .onChange(of: allowsDrag) { enabled in
      guard !enabled else { return }
      stretch = .zero
      lift = 0
      highlight = 0
      dragged = false
    }
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
      .frame(width: WorkspaceHeaderLayout.controlSize, height: WorkspaceHeaderLayout.controlSize)
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
    case .focus: store.focusMode = true
    case .settings: store.openSettings()
    case .skillTree: store.navigate(.skillTree)
    case .milestones: store.sheet = .milestones
    }
  }
}

private struct WorkspaceSearch: View {
  let title: LocalizedStringKey
  @Binding var text: String
  @Binding var expanded: Bool
  let submit: () -> Void
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if #available(macOS 26, *) {
        LiquidGlassPlate(circular: false, leadingPad: 0, verticalPad: 0, allowsDrag: !expanded) { dragged in
          control(acceptClick: !dragged)
        }
      } else {
        control(acceptClick: true)
          .background(.regularMaterial, in: Capsule())
          .overlay { Capsule().strokeBorder(Color.primary.opacity(0.09)).allowsHitTesting(false) }
      }
    }
    .focusedSceneValue(\.workspaceSearch, open)
  }

  private func control(acceptClick: Bool) -> some View {
    let size = WorkspaceHeaderLayout.controlSize
    let actionTitle: LocalizedStringKey = expanded ? "Close search" : "Search"
    return HStack(spacing: 0) {
      if expanded {
        field.transition(.opacity)
      }
      Button {
        if acceptClick { toggle() }
      } label: {
        Image(systemName: expanded ? "xmark" : "magnifyingglass")
          .font(.system(size: 15, weight: .medium))
          .frame(width: size, height: size)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .help(actionTitle)
      .accessibilityLabel(actionTitle)
    }
    .frame(width: expanded ? 260 : size, height: size, alignment: .trailing)
    .clipShape(Capsule())
  }

  private var field: some View {
    HStack(spacing: 8) {
      TextField(title, text: $text)
        .textFieldStyle(.plain)
        .focused($focused)
        .onSubmit(submit)
      if !text.isEmpty {
        Button {
          text = ""
          focused = true
        } label: {
          Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Clear search")
        .help("Clear search")
      }
    }
    .font(.system(size: 13))
    .padding(.leading, 14)
    .onAppear {
      // Install the new field before asking AppKit to move focus away from the page.
      DispatchQueue.main.async { focused = true }
    }
    .onExitCommand(perform: close)
  }

  private func toggle() {
    if expanded {
      close()
    } else {
      open()
    }
  }

  private func open() {
    if expanded {
      focused = true
    } else {
      setExpanded(true)
    }
  }

  private func close() {
    focused = false
    text = ""
    setExpanded(false)
  }

  private func setExpanded(_ value: Bool) {
    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
      expanded = value
    }
  }
}

private struct WorkspaceTabs: NSViewRepresentable {
  @Environment(\.locale) private var locale
  let options: [(title: String, value: Int)]
  @Binding var selection: Int
  let label: String

  func makeCoordinator() -> Coordinator {
    Coordinator(selection: $selection)
  }

  func makeNSView(context: Context) -> NSView {
    let control = context.coordinator.control
    control.trackingMode = .selectOne
    control.segmentDistribution = .fillEqually
    control.target = context.coordinator
    control.action = #selector(Coordinator.selectSegment(_:))
    control.setContentHuggingPriority(.defaultLow, for: .horizontal)
    #if compiler(>=6.4)
    if #available(macOS 27, *) { control.role = .tabs }
    #endif
    if #available(macOS 26, *) {
      control.controlSize = .extraLarge
      control.borderShape = .capsule
      let fontSize = control.font?.pointSize ?? NSFont.systemFontSize(for: control.controlSize)
      control.font = NSFont.systemFont(ofSize: fontSize, weight: .light)
      let glass = NSGlassEffectView()
      glass.contentView = control
      #if compiler(>=6.4)
      if #available(macOS 27, *) { glass.effectIsInteractive = true }
      #endif
      return WorkspaceTabSlot(glass: glass)
    }
    control.controlSize = .large
    return control
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
    guard #available(macOS 26, *), let width = proposal.width, let height = proposal.height else {
      return nil
    }
    return CGSize(width: width, height: height)
  }

  func updateNSView(_ view: NSView, context: Context) {
    let _ = locale
    let control = context.coordinator.control
    context.coordinator.selection = $selection
    control.setAccessibilityLabel(L(label))
    if control.segmentCount != options.count { control.segmentCount = options.count }
    for (index, option) in options.enumerated() {
      let title = L(option.title)
      if control.label(forSegment: index) != title { control.setLabel(title, forSegment: index) }
      if control.tag(forSegment: index) != option.value { control.setTag(option.value, forSegment: index) }
    }
    if let index = options.firstIndex(where: { $0.value == selection }),
      control.selectedSegment != index
    {
      control.selectedSegment = index
    }
  }

  final class Coordinator: NSObject {
    let control = NSSegmentedControl()
    var selection: Binding<Int>

    init(selection: Binding<Int>) { self.selection = selection }

    @objc func selectSegment(_ control: NSSegmentedControl) {
      let index = control.selectedSegment
      guard index >= 0 else { return }
      let value = control.tag(forSegment: index)
      if selection.wrappedValue != value { selection.wrappedValue = value }
    }
  }
}

@available(macOS 26, *)
private final class WorkspaceTabSlot: NSView {
  private let glass: NSGlassEffectView

  init(glass: NSGlassEffectView) {
    self.glass = glass
    super.init(frame: .zero)
    addSubview(glass)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func layout() {
    super.layout()
    guard let trackHeight = glass.contentView?.intrinsicContentSize.height, trackHeight > 0,
      frame.width > 0, frame.height > 0
    else { return }
    // Scale the containing coordinate space and let AppKit lay out the segments at their native height.
    let trackSize = CGSize(width: frame.width * trackHeight / frame.height, height: trackHeight)
    if bounds.size != trackSize { setBoundsSize(trackSize) }
    if glass.frame != bounds { glass.frame = bounds }
    if glass.cornerRadius != trackHeight / 2 { glass.cornerRadius = trackHeight / 2 }
  }
}

struct RootView: View {
  @EnvironmentObject var notifications: Notifications
  @Environment(\.openWindow) private var openWindow
  @Environment(\.locale) private var locale
  @Environment(\.colorScheme) private var scheme
  @AppStorage("style") private var style = "minimal"
  @SceneStorage("mainSidebarVisible") private var sidebarVisible = true
  @EnvironmentObject var store: Store
  @State private var searchVisible = false
  @State private var search = ""
  @State private var searchSubmission = UUID()
  @State private var journalTab = 0
  @State private var questFilter = 0
  var body: some View {
    let _ = locale
    Group {
      if let state = store.state, let summary = store.summary {
        if !state.settings.onboarded {
          OnboardingView()
        } else if store.focusMode {
          FocusView(state: state, summary: summary)
        } else {
          workspace(state: state, summary: summary)
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
    .modifier(WorkspaceWindowChrome())
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

  private func workspace(state: GameState, summary: Summary) -> some View {
    let page = store.page ?? .dashboard
    let searchTitle = searchTitle(for: page)
    let controls = controls(for: page)
    return HStack(spacing: 0) {
      if sidebarVisible {
        SidebarIsland(profile: state.settings) { sidebarVisible = false }
      }
      VStack(spacing: 0) {
        if page != .settings {
          WorkspaceHeader(sidebarHidden: !sidebarVisible) {
            controls
            tabs(for: page)
            Spacer(minLength: 0)
            if let searchTitle {
              WorkspaceSearch(
                title: searchTitle, text: $search, expanded: $searchVisible,
                submit: { searchSubmission = UUID() }
              )
            }
            WindowToolbar()
          }
          .zIndex(1)
        }
        detailPage(page, state: state, summary: summary)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .background {
      if let goBack = controls.goBack {
        WorkspaceBackSwipe(onBack: goBack).allowsHitTesting(false)
      }
    }
    .ignoresSafeArea(.container, edges: .top)
    .onChange(of: store.page) { page in
      closeSearch()
      if page != .journal { journalTab = 0 }
      if page != .quests { questFilter = 0 }
      if page != .skills { store.endSkillEditing() }
      if page != .skillTree && page != .settings { store.questTreeSkill = nil }
    }
    .onChange(of: store.questTreeSkill) { _ in closeSearch() }
    .onDisappear {
      closeSearch()
      journalTab = 0
      questFilter = 0
    }
  }

  @ViewBuilder private func tabs(for page: Page) -> some View {
    switch page {
    case .journal:
      WorkspaceTabs(
        options: [("Entries", 0), ("Activity", 1)], selection: $journalTab,
        label: "Journal filter")
        .frame(width: 166, height: WorkspaceHeaderLayout.controlSize)
    case .quests:
      WorkspaceTabs(
        options: [("Active", 0), ("Closed", 1), ("All", 2)], selection: $questFilter,
        label: "Quest status")
        .frame(width: 190, height: WorkspaceHeaderLayout.controlSize)
    default: EmptyView()
    }
  }

  private func searchTitle(for page: Page) -> LocalizedStringKey? {
    switch page {
    case .quests: "Search quests"
    case .journal: "Search journal"
    case .skillTree: store.questTreeSkill == nil ? "Find a skill" : "Find a quest"
    default: nil
    }
  }

  private func closeSearch() {
    searchVisible = false
    search = ""
  }

  private func controls(for page: Page) -> WorkspaceControls {
    WorkspaceControls(
      showSidebar: sidebarVisible ? nil : { sidebarVisible = true },
      goBack: page == .settings || page == .skillTree ? goBack : nil)
  }

  private func paintWindow() {
    for window in NSApp.windows where window.title == "ASCEND" {
      window.backgroundColor = AppChrome.windowBackground(style: style, scheme: scheme)
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
    case .skillTree:
      SkillTreeView(state: state, summary: summary, search: $search, searchSubmission: searchSubmission)
    case .quests: QuestsView(state: state, summary: summary, search: $search, filter: $questFilter)
    case .balance: BalanceView(state: state, summary: summary)
    case .analytics: AnalyticsView(state: state, summary: summary)
    case .journal: JournalView(state: state, search: $search, tab: $journalTab)
    case .settings:
      SettingsView(workspaceControls: controls(for: page))
    }
  }
}

struct WorkspaceControls: View {
  let showSidebar: (() -> Void)?
  let goBack: (() -> Void)?

  var body: some View {
    if let showSidebar {
      SidebarToggle(visible: false, action: showSidebar)
    }
    if let goBack {
      if #available(macOS 26, *) {
        GlassIconButton(symbol: "chevron.left", title: "Back", action: goBack)
      } else {
        Button(action: goBack) { Image(systemName: "chevron.left").frame(width: 30, height: 30) }
          .buttonStyle(.borderless)
          .help("Back")
          .accessibilityLabel("Back")
      }
    }
  }
}

private struct WorkspaceBackSwipe: NSViewRepresentable {
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
    context.coordinator.onBack = onBack
  }
  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.stop()
  }

  final class Coordinator {
    var onBack: () -> Void
    var monitor: Any?
    weak var view: NSView?
    private var tracking = BackSwipeTracking()
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
        event.hasPreciseScrollingDeltas
      else { return event }
      switch tracking.update(
        phase: event.phase, momentum: !event.momentumPhase.isEmpty,
        dx: event.scrollingDeltaX, dy: event.scrollingDeltaY,
        canPanBack: { self.canPanTowardStart(event, in: window) }
      ) {
      case .forward: return event
      case .consume: return nil
      case .goBack:
        onBack()
        return nil
      }
    }

    private func canPanTowardStart(_ event: NSEvent, in window: NSWindow) -> Bool {
      guard let content = window.contentView, let container = content.superview else { return false }
      let location = container.convert(event.locationInWindow, from: nil)
      var target = content.hitTest(location)
      while let hit = target {
        if let scroll = hit as? NSScrollView, let document = scroll.documentView,
          scroll.documentVisibleRect.minX > document.bounds.minX + 1
        {
          return true
        }
        target = hit.superview
      }
      return false
    }
  }
}

private struct BackSwipeTracking {
  enum Result { case forward, consume, goBack }
  private enum State { case waiting, forwarding, tracking(CGFloat), finished }
  private var state = State.waiting

  mutating func update(
    phase: NSEvent.Phase, momentum: Bool, dx: CGFloat, dy: CGFloat, canPanBack: () -> Bool
  ) -> Result {
    if momentum {
      if case .finished = state { return .consume }
      return .forward
    }
    if phase == .began {
      state = .waiting
      return .forward
    }
    switch (state, phase) {
    case (.waiting, .changed):
      guard abs(dx) >= 0.8 || abs(dy) >= 0.8 else { return .forward }
      guard dx > 1, dx > abs(dy) * 1.2, !canPanBack() else {
        state = .forwarding
        return .forward
      }
      state = .tracking(dx)
      return .consume
    case (.tracking(let travel), .changed):
      state = .tracking(max(0, travel + dx))
      return .consume
    case (.tracking(let travel), .ended):
      state = .finished
      return travel > 90 ? .goBack : .consume
    case (.tracking, .cancelled):
      state = .finished
      return .consume
    default:
      return .forward
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
