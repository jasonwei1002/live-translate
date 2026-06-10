import AppKit
import SwiftUI

/// Root wrapper pinning the SwiftUI content's intrinsic size to the panel
/// size. Without it, NSHostingView reports the (much smaller) subtitle bar as
/// intrinsic size and the borderless panel collapses around it, leaving zero
/// width for the text.
private struct OverlayRoot: View {
  var subtitle: SubtitleState
  var appearance: SubtitleAppearance

  var body: some View {
    SubtitleOverlayView(subtitle: subtitle, appearance: appearance)
      .frame(
        width: SubtitleOverlayController.panelSize.width,
        height: SubtitleOverlayController.panelSize.height
      )
  }
}

@MainActor
final class SubtitleOverlayController {
  private var panel: NSPanel?
  private var hostingView: DraggableHostingView<OverlayRoot>?
  private var subtitle = SubtitleState()
  private var appearance = SubtitleAppearance()
  private var isVisible = false
  private var moveObserver: NSObjectProtocol?

  nonisolated private static let originXKey = "overlayOriginX"
  nonisolated private static let originYKey = "overlayOriginY"
  static let panelSize = NSSize(width: 900, height: 190)

  func setVisible(_ visible: Bool) {
    isVisible = visible
    if visible {
      show()
    } else {
      panel?.orderOut(nil)
    }
  }

  func update(appearance: SubtitleAppearance) {
    self.appearance = appearance
    hostingView?.rootView = OverlayRoot(subtitle: subtitle, appearance: appearance)
  }

  func update(subtitle: SubtitleState) {
    self.subtitle = subtitle
    hostingView?.rootView = OverlayRoot(subtitle: subtitle, appearance: appearance)
    // Reassigning rootView already re-renders; only order the panel front when
    // it should be visible but isn't yet on screen (avoids a window-server
    // round-trip on every subtitle tick). Never reposition here so the user's
    // dragged position survives subtitle updates.
    if isVisible, panel?.isVisible != true {
      show()
    }
  }

  private func show() {
    if panel == nil {
      createPanel()
    }
    panel?.orderFrontRegardless()
  }

  private func createPanel() {
    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = false          // allow grabbing the subtitle to drag it
    panel.isMovableByWindowBackground = true  // drag from anywhere on the overlay
    panel.level = .screenSaver
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

    let hostingView = DraggableHostingView(
      rootView: OverlayRoot(subtitle: subtitle, appearance: appearance))
    // Never let SwiftUI's intrinsic content size drive the window: with the
    // default sizing options the borderless panel collapses to the empty
    // subtitle's padding (~110×53), leaving zero width for the text itself.
    hostingView.sizingOptions = []
    hostingView.frame = panel.contentView?.bounds ?? .zero
    hostingView.autoresizingMask = [.width, .height]
    panel.contentView = hostingView

    self.panel = panel
    self.hostingView = hostingView

    applyInitialPosition(to: panel)

    // Persist the user's chosen position whenever they drag the overlay.
    moveObserver = NotificationCenter.default.addObserver(
      forName: NSWindow.didMoveNotification,
      object: panel,
      queue: .main
    ) { note in
      guard let window = note.object as? NSWindow else { return }
      let origin = window.frame.origin
      UserDefaults.standard.set(Double(origin.x), forKey: Self.originXKey)
      UserDefaults.standard.set(Double(origin.y), forKey: Self.originYKey)
    }
  }

  private func applyInitialPosition(to panel: NSPanel) {
    let defaults = UserDefaults.standard
    if defaults.object(forKey: Self.originXKey) != nil,
       defaults.object(forKey: Self.originYKey) != nil {
      let origin = NSPoint(
        x: defaults.double(forKey: Self.originXKey),
        y: defaults.double(forKey: Self.originYKey)
      )
      if isOnScreen(origin: origin, size: panel.frame.size) {
        panel.setFrameOrigin(origin)
        return
      }
    }
    positionAtDefault(panel)
  }

  private func positionAtDefault(_ panel: NSPanel) {
    guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
    let visible = screen.visibleFrame
    let size = panel.frame.size
    let x = visible.midX - size.width / 2
    let y = visible.minY + max(72, visible.height * 0.09)
    panel.setFrameOrigin(NSPoint(x: x, y: y))
  }

  private func isOnScreen(origin: NSPoint, size: NSSize) -> Bool {
    let frame = NSRect(origin: origin, size: size)
    return NSScreen.screens.contains { $0.visibleFrame.intersects(frame) }
  }

  deinit {
    if let moveObserver {
      NotificationCenter.default.removeObserver(moveObserver)
    }
  }
}

/// Hosting view whose whole area initiates a window drag, so the borderless
/// overlay panel can be dragged from anywhere on it.
private final class DraggableHostingView<Content: View>: NSHostingView<Content> {
  override var mouseDownCanMoveWindow: Bool { true }
}
