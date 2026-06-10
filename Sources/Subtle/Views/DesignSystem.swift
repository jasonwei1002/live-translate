import SwiftUI

/// Design tokens from the Subtle design handoff (macOS native light style).
enum Theme {
  /// Accent (#0A7AFF, the design's default 点缀色): toggles, meter, links.
  static let accent = Color(red: 10 / 255, green: 122 / 255, blue: 255 / 255)
  /// Error text and banners.
  static let danger = Color(red: 0.83, green: 0.23, blue: 0.28)
}
