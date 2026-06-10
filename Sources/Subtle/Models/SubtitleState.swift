import Foundation

struct SubtitleState: Equatable {
  var sourceText = ""
  /// Translated lines, oldest first; the last line is the active one (the
  /// in-progress segment, or the most recently completed sentence). Lines are
  /// rendered independently so committed text never reflows.
  var translatedLines: [String] = []
  /// Shown as a placeholder while the service runs but no subtitle has
  /// arrived yet, so "no sound" is distinguishable from "not working".
  var isListening = false
  /// Session-failure message surfaced briefly on the overlay itself.
  var errorText = ""
  var lastUpdated = Date.distantPast

  var hasText: Bool {
    !sourceText.isEmpty || !translatedLines.isEmpty
  }

  /// Drives overlay chrome visibility (placeholder and errors need it too).
  var hasVisibleContent: Bool {
    hasText || isListening || !errorText.isEmpty
  }
}
