import AppKit
import SwiftUI

struct SidebarIsland: View {
  @EnvironmentObject private var store: Store
  @Environment(\.colorScheme) private var scheme
  @SceneStorage("mainSidebarWidth") private var savedWidth = 204.0
  @GestureState private var dragOffset: CGFloat = 0
  let profile: Profile
  let hide: () -> Void

  private let inset: CGFloat = 8
  private var shape: RoundedRectangle {
    if #available(macOS 26, *) {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
    } else {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
    }
  }
  private var selection: Binding<Page?> {
    Binding(
      get: { store.page ?? .dashboard },
      set: { if let page = $0 { store.navigate(page) } })
  }

  var body: some View {
    HStack(spacing: 0) {
      VStack(spacing: 0) {
        SidebarToggle(visible: true, action: hide)
          .padding(.trailing, 8)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .frame(height: 44)
          .background { WindowDragRegion() }

        List(Page.menu, selection: selection) { page in
          Label(LocalizedStringKey(page.rawValue), systemImage: page.symbol)
            .font(.system(size: 13, weight: .medium))
            .padding(.vertical, 4)
            .tag(page)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .accessibilityLabel("Sidebar")

        Divider().padding(.horizontal, 12)
        account
      }
      .frame(width: boundedWidth(savedWidth + dragOffset))
      .clipShape(shape)
      .background {
        shape
          .fill(AppChrome.island(scheme: scheme))
          .overlay { shape.strokeBorder(Color.primary.opacity(0.09), lineWidth: 1) }
          .shadow(color: .black.opacity(scheme == .dark ? 0.19 : 0.07), radius: 8, y: 2)
      }

      resizeHandle
    }
    .padding(.leading, inset)
    .padding(.vertical, inset)
  }

  private var account: some View {
    let selected = store.page == .character
    return Button {
      store.navigate(.character)
    } label: {
      HStack(spacing: 8) {
        ProfileAvatar(encodedImage: profile.avatar, size: 32, circular: true)
          .accessibilityHidden(true)
        Group {
          if profile.name.isEmpty { Text("Character") } else { Text(verbatim: profile.name) }
        }
          .font(.system(size: 13, weight: .medium))
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(8)
      .background {
        RoundedRectangle(cornerRadius: 9)
          .fill(selected ? Color.accentColor.opacity(0.16) : Color.clear)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .padding(8)
  }

  private var resizeHandle: some View {
    let handle = Color.clear
      .frame(width: inset)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
          .updating($dragOffset) { value, offset, _ in offset = value.translation.width }
          .onEnded { value in
            savedWidth = boundedWidth(savedWidth + value.translation.width)
          }
      )
      .accessibilityLabel("Adjust divider")
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: savedWidth = boundedWidth(savedWidth + 16)
        case .decrement: savedWidth = boundedWidth(savedWidth - 16)
        @unknown default: break
        }
      }
    return Group {
      if #available(macOS 15, *) {
        handle.pointerStyle(.columnResize)
      } else {
        handle
      }
    }
  }

  private func boundedWidth(_ width: CGFloat) -> CGFloat { min(max(width, 180), 250) }
}

struct SidebarToggle: View {
  let visible: Bool
  let action: () -> Void

  var body: some View {
    let label = LocalizedStringKey(visible ? "Hide Sidebar" : "Show Sidebar")
    Button(action: action) {
      Image(systemName: "sidebar.left")
        .font(.system(size: 13, weight: .medium))
        .frame(width: 30, height: 30)
    }
    .buttonStyle(.borderless)
    .help(label)
    .accessibilityLabel(label)
  }
}

struct WorkspaceHeader<Content: View>: View {
  var sidebarHidden: Bool
  @ViewBuilder let content: () -> Content

  var body: some View {
    HStack(spacing: 10, content: content)
      .padding(.leading, sidebarHidden ? 94 : 16)
      .padding(.trailing, 20)
      .frame(height: 52)
      .background { WindowDragRegion() }
  }
}

struct WorkspaceWindowChrome: ViewModifier {
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26, *) {
      content
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .background { UnifiedWindowToolbar().allowsHitTesting(false) }
    } else {
      content
    }
  }
}

@available(macOS 26, *)
private struct UnifiedWindowToolbar: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { ChromeView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class ChromeView: NSView {
    private let toolbarIdentifier = NSToolbar.Identifier("ASCEND.WindowChrome")

    override func viewWillMove(toWindow newWindow: NSWindow?) {
      if let window {
        NotificationCenter.default.removeObserver(self, name: nil, object: window)
      }
      super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window else { return }
      let notifications = NotificationCenter.default
      for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
        notifications.addObserver(
          self, selector: #selector(fullScreenDidChange), name: name, object: window)
      }

      // An empty unified toolbar lets AppKit inset the real window buttons.
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window, self.window === window else { return }
        if window.toolbar == nil {
          let toolbar = NSToolbar(identifier: self.toolbarIdentifier)
          toolbar.allowsUserCustomization = false
          window.toolbarStyle = .unified
          window.toolbar = toolbar
          window.titlebarAppearsTransparent = true
          window.titlebarSeparatorStyle = .none
        }
        self.updateChrome(for: window)
      }
    }

    @objc private func fullScreenDidChange(_ notification: Notification) {
      if let window { updateChrome(for: window) }
    }

    private func updateChrome(for window: NSWindow) {
      let fullScreen = window.styleMask.contains(.fullScreen)
      // In full screen AppKit can draw the empty toolbar over the workspace header.
      if let toolbar = window.toolbar, toolbar.identifier == toolbarIdentifier {
        toolbar.isVisible = !fullScreen
      }

      // macOS 27 exposes the window-frame radius through this AppKit selector.
      // Keep the native shape when the selector is unavailable.
      guard #available(macOS 27, *) else { return }
      let selector = NSSelectorFromString("_setCornerRadius:")
      guard window.responds(to: selector), let implementation = window.method(for: selector)
      else { return }
      typealias SetRadius = @convention(c) (AnyObject, Selector, Double) -> Void
      unsafeBitCast(implementation, to: SetRadius.self)(window, selector, fullScreen ? 0 : 28)
    }
  }
}

private struct WindowDragRegion: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView { DragView() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class DragView: NSView {
    override func mouseDown(with event: NSEvent) {
      guard let window else { return }
      if event.clickCount == 2 {
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.miniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
      } else {
        window.performDrag(with: event)
      }
    }
  }
}
