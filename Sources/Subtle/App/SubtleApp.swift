import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Idempotent; also called from AppState.init — whichever runs first wins.
    LegacyDefaultsMigrator.migrateIfNeeded()
    // Pure menu-bar tool (design decision): no Dock icon, no main window.
    NSApp.setActivationPolicy(.accessory)
    // First launch (or key cleared): open Settings directly so start() cannot
    // fail later for a missing key. Delay lets the menu-bar scene settle.
    let provider = TranslationProvider.loadSelected(from: .standard)
    if (UserDefaults.standard.string(forKey: provider.apiKeyDefaultsKey) ?? "").isEmpty {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }
}

@main
struct SubtleApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var appState = AppState()

  var body: some Scene {
    Settings {
      SettingsView()
        .environmentObject(appState)
    }
    .windowResizability(.contentSize)

    MenuBarExtra {
      MenuBarContentView()
        .environmentObject(appState)
    } label: {
      // Drive the icon from a label view that observes appState so it tracks
      // isRunning, instead of reading state in the non-reactive Scene builder.
      MenuBarGlyph(isRunning: appState.isRunning)
    }
    .menuBarExtraStyle(.window)
  }
}

/// Menu-bar status icon, same construction as the app icon: three waveform
/// bars over two caption lines. Monochrome template when idle (so it adapts
/// to menu-bar appearance), accent-tinted while the service is running.
private struct MenuBarGlyph: View {
  let isRunning: Bool

  var body: some View {
    Image(nsImage: Self.glyphImage(running: isRunning))
  }

  private static func glyphImage(running: Bool) -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
      let color = running
        ? NSColor(srgbRed: 10 / 255, green: 122 / 255, blue: 255 / 255, alpha: 1)
        : NSColor.black
      func stroke(from: NSPoint, to: NSPoint, alpha: CGFloat = 1) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = 1.65
        path.lineCapStyle = .round
        color.withAlphaComponent(alpha).setStroke()
        path.stroke()
      }
      // Waveform (design coordinates × 0.75 → 18 pt canvas).
      stroke(from: NSPoint(x: 4.5, y: 5.6), to: NSPoint(x: 4.5, y: 7.9))
      stroke(from: NSPoint(x: 9, y: 3.4), to: NSPoint(x: 9, y: 10.1))
      stroke(from: NSPoint(x: 13.5, y: 4.5), to: NSPoint(x: 13.5, y: 9))
      // Caption lines: short dim + long solid.
      stroke(from: NSPoint(x: 6.4, y: 12.75), to: NSPoint(x: 11.6, y: 12.75), alpha: 0.45)
      stroke(from: NSPoint(x: 3.75, y: 15.75), to: NSPoint(x: 14.25, y: 15.75))
      return true
    }
    image.isTemplate = !running
    return image
  }
}
