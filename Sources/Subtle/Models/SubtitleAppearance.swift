import Foundation

/// User-selectable look of the floating subtitle bar (from the Subtle design
/// handoff): classic dark bar, light frosted glass, or background-free
/// cinema-style outlined text.
enum SubtitleStyle: String, CaseIterable, Identifiable {
  case darkBar
  case frosted
  case outline

  var id: String { rawValue }

  var title: String {
    switch self {
    case .darkBar: return "深色条"
    case .frosted: return "毛玻璃"
    case .outline: return "描边"
    }
  }
}

/// Rendering parameters for the subtitle overlay; persisted via UserDefaults
/// and editable in the「字幕样式」settings tab.
struct SubtitleAppearance: Equatable {
  var style: SubtitleStyle = .darkBar
  /// Point size of the translated line; the source line renders at 0.62×.
  var fontSize: Double = 24
  /// Background opacity for the bar styles; drives shadow depth for outline.
  var backgroundOpacity: Double = 0.62
}
