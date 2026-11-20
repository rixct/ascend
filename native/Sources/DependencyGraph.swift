import AppKit
import SwiftUI

struct DependencyGraphItem: Identifiable {
  let id: String
  let title: String
  let symbol: String
  let color: Color
}
struct DependencyGraphLegend: Identifiable {
  let title: String
  let color: Color
  var id: String { title }
}

/// Shared viewport-sized renderer for skill and quest dependency graphs.
struct DependencyGraph<Node: View>: View {
  @Environment(\.locale) private var locale
  let layout: SkillTreeLayout
  let items: [DependencyGraphItem]
  @Binding var selected: String?
  let focusRequest: UUID
  let route: Set<String>
  let fulfilled: Set<String>
  let searchTitle: LocalizedStringKey
  let countText: String
  let legend: [DependencyGraphLegend]
  let onPick: (String) -> Void
  @ViewBuilder let node: (String, Bool) -> Node
  @State private var search = ""
  @State private var zoom: CGFloat = 0.85
  @State private var origin = CGPoint.zero
  private var matches: [DependencyGraphItem] {
    guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
    return items.filter { $0.title.localizedCaseInsensitiveContains(search) }
  }
  var body: some View {
    let _ = locale
    let matchingIDs = Set(matches.map(\.id))
    GeometryReader { geometry in
      ScrollViewReader { proxy in
        VStack(spacing: 0) {
          HStack(spacing: 12) {
            CanvasSearchField(title: searchTitle, text: $search) {
              if let first = matches.first {
                select(first.id, proxy: proxy)
                search = ""
              }
            }
            Text(countText)
              .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
          }.padding(.horizontal, 16).padding(.vertical, 11)
          RowDivider()
          ZStack(alignment: .topLeading) {
            GeometryReader { viewport in
              connections(viewport: viewport.size)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            ScrollView([.horizontal, .vertical]) {
              HStack(
                alignment: .top, spacing: SkillTreeLayout.columnSpacing - SkillTreeLayout.card.width
              ) {
                ForEach(Array(layout.columns.indices), id: \.self) { column in
                  let ids = layout.columns[column]
                  let firstY = ids.first.flatMap { layout.frames[$0]?.minY } ?? 72
                  VStack(spacing: 0) {
                    Text(column == 0 ? L("Foundation") : L("Stage %d", column))
                      .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                      .frame(width: SkillTreeLayout.card.width, height: 24, alignment: .leading)
                    Color.clear.frame(height: max(0, firstY - 48))
                    VStack(spacing: SkillTreeLayout.rowSpacing - SkillTreeLayout.card.height) {
                      ForEach(ids, id: \.self) { id in
                        if let frame = layout.frames[id] {
                          Group {
                            if isVisible(frame, size: geometry.size) {
                              node(id, !search.isEmpty && !matchingIDs.contains(id))
                            } else {
                              Color.clear
                            }
                          }
                          .frame(width: frame.width, height: frame.height).id(id)
                        }
                      }
                    }
                  }
                  .frame(height: layout.size.height - 24, alignment: .top)
                }
              }
              .padding(.horizontal, 44).padding(.top, 24)
              .id(locale.identifier)
              .frame(width: layout.size.width, height: layout.size.height)
              .scaleEffect(zoom, anchor: .topLeading)
              .frame(
                width: layout.size.width * zoom, height: layout.size.height * zoom,
                alignment: .topLeading
              )
              .background { TreeScrollObserver { origin = $0 } }
            }
            if !search.isEmpty { searchResults(proxy: proxy) }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
          RowDivider()
          HStack(spacing: 10) {
            ForEach(legend) { item in
              HStack(spacing: 4) {
                Circle().fill(item.color).frame(width: 5, height: 5)
                Text(LocalizedStringKey(item.title)).font(.system(size: 10))
              }.foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
              zoom = max(0.35, zoom - 0.15)
            } label: {
              Image(systemName: "minus")
            }
            .help("Zoom out").disabled(zoom <= 0.35)
            Button {
              zoom = min(
                1.25,
                max(
                  0.35,
                  min(
                    (geometry.size.width - 20) / layout.size.width,
                    (geometry.size.height - 126) / layout.size.height)))
            } label: {
              Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fit tree")
            Button {
              zoom = min(1.6, zoom + 0.15)
            } label: {
              Image(systemName: "plus")
            }
            .help("Zoom in").disabled(zoom >= 1.6)
          }
          .buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 16).padding(
            .vertical, 14)
        }
        .onChange(of: zoom) { _ in
          if let selected { proxy.scrollTo(selected, anchor: .center) }
        }
        .onChange(of: focusRequest) { _ in
          if let selected { proxy.scrollTo(selected, anchor: .center) }
        }
      }
    }
  }
  private func select(_ id: String, proxy: ScrollViewProxy) {
    selected = id
    proxy.scrollTo(id, anchor: .center)
    onPick(id)
  }
  private func isVisible(_ frame: CGRect, size: CGSize) -> Bool {
    let visible = CGRect(
      x: -origin.x / zoom, y: -origin.y / zoom, width: size.width / zoom, height: size.height / zoom
    )
    return frame.intersects(visible.insetBy(dx: -120, dy: -120))
  }
  private func connections(viewport: CGSize) -> some View {
    Canvas { context, size in
      let visible = CGRect(
        x: -origin.x / zoom, y: -origin.y / zoom, width: size.width / zoom,
        height: size.height / zoom)
      context.translateBy(x: origin.x, y: origin.y)
      context.scaleBy(x: zoom, y: zoom)
      // The canvas is viewport-sized; scrolling a large tree never allocates a giant bitmap.
      let step: CGFloat = 28
      for x in stride(from: floor(visible.minX / step) * step, through: visible.maxX, by: step) {
        for y in stride(from: floor(visible.minY / step) * step, through: visible.maxY, by: step) {
          context.fill(
            Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)),
            with: .color(.secondary.opacity(0.12)))
        }
      }
      for edge in layout.edges {
        guard let source = layout.frames[edge.source], let target = layout.frames[edge.target]
        else { continue }
        let start = CGPoint(x: source.maxX, y: source.midY)
        let end = CGPoint(x: target.minX, y: target.midY)
        let bounds = CGRect(
          x: min(start.x, end.x), y: min(start.y, end.y), width: max(1, abs(end.x - start.x)),
          height: max(1, abs(end.y - start.y)))
        guard bounds.insetBy(dx: -12, dy: -12).intersects(visible) else { continue }
        let highlight = route.contains(edge.source) && route.contains(edge.target)
        let satisfied = fulfilled.contains(edge.source)
        let color: Color =
          highlight
          ? AppStyle.accent
          : (satisfied ? AppStyle.mint.opacity(0.5) : Color.secondary.opacity(0.24))
        var path = Path()
        path.move(to: start)
        let bend = max(36, abs(end.x - start.x) * 0.48)
        path.addCurve(
          to: end, control1: CGPoint(x: start.x + bend, y: start.y),
          control2: CGPoint(x: end.x - bend, y: end.y))
        context.stroke(
          path, with: .color(color),
          style: StrokeStyle(
            lineWidth: highlight ? 2 : 1.25, dash: satisfied || highlight ? [] : [4, 5]))
        context.fill(
          Path(ellipseIn: CGRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6)),
          with: .color(color))
        var arrow = Path()
        arrow.move(to: CGPoint(x: end.x - 6, y: end.y - 3))
        arrow.addLine(to: end)
        arrow.addLine(to: CGPoint(x: end.x - 6, y: end.y + 3))
        context.stroke(arrow, with: .color(color), lineWidth: 1.5)
      }
    }.frame(width: viewport.width, height: viewport.height)
  }
  private func searchResults(proxy: ScrollViewProxy) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      if matches.isEmpty {
        Text("No matching items").font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
      } else {
        ForEach(matches.prefix(8)) { item in
          Button {
            select(item.id, proxy: proxy)
            search = ""
          } label: {
            HStack {
              Image(systemName: item.symbol).foregroundStyle(item.color)
              Text(item.title).lineLimit(1)
              Spacer()
              Image(systemName: "arrow.turn.down.left").foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(12).contentShape(Rectangle())
          }.buttonStyle(.plain)
        }
      }
    }
    .frame(maxWidth: 300, alignment: .leading).background(
      .regularMaterial, in: RoundedRectangle(cornerRadius: 12)
    )
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)) }
    .shadow(color: .black.opacity(0.15), radius: 12, y: 5).padding(12)
  }

}

/// Read the native clip view: macOS doesn't consistently invalidate geometry preferences
/// when a two-axis SwiftUI scroll view moves. The observer is removed with the view.
private struct TreeScrollObserver: NSViewRepresentable {
  let onChange: (CGPoint) -> Void
  func makeNSView(context: Context) -> TreeClipTracker {
    let view = TreeClipTracker()
    view.onChange = onChange
    return view
  }
  func updateNSView(_ view: TreeClipTracker, context: Context) { view.onChange = onChange }
  static func dismantleNSView(_ view: TreeClipTracker, coordinator: ()) { view.stop() }
}

private final class TreeClipTracker: NSView {
  var onChange: (CGPoint) -> Void = { _ in }
  private var observer: NSObjectProtocol?
  private weak var clip: NSClipView?
  private var pending: CGPoint?
  private var scheduled = false
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      stop()
      return
    }
    DispatchQueue.main.async { [weak self] in self?.bind() }
  }
  override func viewDidMoveToSuperview() {
    super.viewDidMoveToSuperview()
    DispatchQueue.main.async { [weak self] in self?.bind() }
  }
  private func bind() {
    guard window != nil, let scroll = enclosingScrollView else { return }
    if clip !== scroll.contentView {
      stop()
      clip = scroll.contentView
      scroll.contentView.postsBoundsChangedNotifications = true
      observer = NotificationCenter.default.addObserver(
        forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
      ) { [weak self] _ in self?.report() }
    }
    report()
  }
  private func report() {
    guard let scroll = enclosingScrollView, let document = scroll.documentView else { return }
    let visible = scroll.documentVisibleRect
    let y = document.isFlipped ? visible.minY : document.bounds.maxY - visible.maxY
    pending = CGPoint(x: -visible.minX, y: -y)
    guard !scheduled else { return }
    scheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      scheduled = false
      guard let point = pending else { return }
      pending = nil
      onChange(point)
    }
  }
  func stop() {
    if let observer { NotificationCenter.default.removeObserver(observer) }
    observer = nil
    clip = nil
    pending = nil
  }
  deinit { stop() }
}
