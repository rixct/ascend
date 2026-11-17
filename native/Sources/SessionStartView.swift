import AVFoundation
import SwiftUI

struct SessionStartView: View {
  @EnvironmentObject private var store: Store
  @EnvironmentObject private var presence: PresenceMonitor
  @Environment(\.locale) private var locale
  let questID: String
  @AppStorage("strictModeEnabled") private var strictMode = false
  @State private var useCamera = true
  private var cameraRequired: Bool { strictMode || store.state?.settings.strict_mode == true }
  var body: some View {
    let _ = locale
    VStack(alignment: .leading, spacing: 18) {
      Text("Start session").font(.system(size: 21, weight: .semibold))
      Text(store.state?.quest(questID)?.title ?? L("Session"))
        .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2)
      SettingsGroup {
        HStack(spacing: 8) {
          Toggle("Use camera for this session", isOn: $useCamera).disabled(store.busy || cameraRequired)
          HintButton(text: "Choose before starting. Camera mode cannot be changed during the session.")
        }
      }
      if useCamera {
        ZStack {
          RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.9))
          if let session = presence.previewSession {
            StrictCameraPreview(session: session).clipShape(RoundedRectangle(cornerRadius: 12))
          } else {
            VStack(spacing: 12) {
              Image(systemName: "camera").font(.system(size: 30, weight: .light)).foregroundStyle(.white.opacity(0.7))
              Button(L(presence.requesting ? "Waiting for permission…" : "Enable camera")) {
                presence.enableForPreparation()
              }.disabled(presence.requesting || store.busy)
            }
          }
          VStack {
            Spacer()
            Label(L(presence.statusKey), systemImage: presence.detected ? "person.fill.checkmark" : "person.crop.rectangle")
              .font(.system(size: 11, weight: .medium)).padding(10).foregroundStyle(.white)
              .background(.black.opacity(0.55), in: Capsule()).padding(12)
          }.allowsHitTesting(false)
        }.frame(height: 204)
        if let key = presence.failureKey {
          HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(AppStyle.amber)
            Text(L(key)).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
          }
          Button("Open camera settings…") { presence.openSettings() }.buttonStyle(.borderless)
        }
        HStack {
          Spacer()
          HintButton(text: "Keep your face visible. Frames are processed on this Mac and are not recorded.")
        }
      }
      Divider()
      HStack {
        Button("Cancel") { presence.cancelPreparation(); store.sheet = nil }
          .keyboardShortcut(.cancelAction).disabled(store.busy)
        Spacer()
        Button("Start session") { store.confirmSessionStart(questID, useCamera: useCamera) }
          .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
          .disabled(store.busy || (useCamera && !presence.ready))
      }
    }
    .padding(26).frame(width: 500).controlSize(.large)
    .toggleStyle(TrailingSwitchStyle())
    .onAppear {
      if cameraRequired { useCamera = true }
      presence.beginPreparation()
    }
    .onChange(of: useCamera) { value in if !value { presence.stopPreparationCamera() } }
    .onDisappear { presence.cancelPreparation() }
    .interactiveDismissDisabled(store.busy)
  }
}

private struct StrictCameraPreview: NSViewRepresentable {
  let session: AVCaptureSession
  func makeNSView(context: Context) -> StrictPreviewView {
    let view = StrictPreviewView()
    view.preview.session = session
    return view
  }
  func updateNSView(_ view: StrictPreviewView, context: Context) {
    if view.preview.session !== session { view.preview.session = session }
  }
  static func dismantleNSView(_ view: StrictPreviewView, coordinator: ()) { view.preview.session = nil }
}
private final class StrictPreviewView: NSView {
  let preview = AVCaptureVideoPreviewLayer()
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    preview.videoGravity = .resizeAspectFill
    layer?.addSublayer(preview)
  }
  required init?(coder: NSCoder) { return nil }
  override func layout() { super.layout(); preview.frame = bounds }
}

struct StrictSessionStatus: View {
  @EnvironmentObject private var store: Store
  @EnvironmentObject private var presence: PresenceMonitor
  @Environment(\.locale) private var locale
  let active: ActiveSession
  @State private var confirmDiscard = false
  var body: some View {
    let _ = locale
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: active.isCounting ? "person.fill.checkmark" : "camera.fill")
        .foregroundStyle(active.isCounting ? AppStyle.mint : AppStyle.amber)
      VStack(alignment: .leading, spacing: 5) {
        Text("Strict session").font(.system(size: 12, weight: .semibold))
        Text(active.running ? L(presence.statusKey) : L("Session paused"))
          .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let key = presence.failureKey { Text(L(key)).font(.system(size: 11)).foregroundStyle(AppStyle.amber) }
      }
      Spacer(minLength: 4)
      Button { confirmDiscard = true } label: { Image(systemName: "xmark.circle") }
        .buttonStyle(.plain).foregroundStyle(.secondary).help("Discard strict session…")
    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(AppStyle.accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
      .confirmationDialog("Discard this session?", isPresented: $confirmDiscard, titleVisibility: .visible) {
        Button("Discard session", role: .destructive) { store.send("discard_session", ["id": active.id]) }
        Button("Cancel", role: .cancel) {}
      } message: { Text("This session's time and notes will not be saved.") }
  }
}
