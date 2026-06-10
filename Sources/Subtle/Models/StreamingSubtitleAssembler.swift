import Foundation

struct StreamingSubtitleAssembler {
  private var current = ""
  /// Recently committed sentences, oldest first. Kept so fast speech does not
  /// overwrite a finished sentence before the viewer can read it: the display
  /// rolls like live captions instead of replacing the whole line.
  private var committedHistory: [String] = []
  /// Soft cap on displayText length; whole oldest sentences are dropped first,
  /// the in-progress segment is never trimmed.
  private let displayCharacterBudget: Int
  private static let maxHistorySegments = 3

  init(displayCharacterBudget: Int = 100) {
    self.displayCharacterBudget = displayCharacterBudget
  }

  var displayText: String {
    var parts = committedHistory
    if !current.isEmpty {
      parts.append(current)
    }
    guard !parts.isEmpty else { return "" }

    // Evict oldest finished sentences until the joined text fits the budget;
    // always keep the newest part even when it alone exceeds the budget.
    var totalCount = parts.reduce(0) { $0 + $1.count }
    while parts.count > 1 && totalCount > displayCharacterBudget {
      totalCount -= parts.removeFirst().count
    }

    return parts.dropFirst().reduce(parts[0]) { Self.join($0, $1) }
  }

  /// The overlay's single display line: the in-progress segment while one is
  /// open, otherwise the most recently committed sentence — kept on screen
  /// between segments so it can finish being read before the next one
  /// replaces it (stacked history lines read as visual clutter; 2026-06-10
  /// user decision).
  var displayLines: [String] {
    if !current.isEmpty {
      return [current]
    }
    if let latest = committedHistory.last {
      return [latest]
    }
    return []
  }

  mutating func beginSegment() {
    current = ""
  }

  /// Ingests a streaming fragment; returns true when the display text changed
  /// (or should be republished).
  mutating func ingest(_ text: String) -> Bool {
    let normalized = Self.normalized(text)
    guard !normalized.isEmpty else { return false }

    if current.isEmpty {
      current = normalized
      return true
    }

    if normalized == current {
      return false
    }

    if normalized.hasPrefix(current) {
      current = normalized
      return true
    }

    if current.hasPrefix(normalized) {
      return true
    }

    if let merged = Self.mergeOverlapping(current, normalized) {
      current = merged
    } else {
      current = Self.join(current, normalized)
    }

    return true
  }

  /// Commits the segment, preferring the server's authoritative full sentence
  /// over the locally accumulated partials, falling back to the accumulation
  /// only when the server text is empty. Returns true when there was text to
  /// commit.
  mutating func endSegment(authoritative text: String) -> Bool {
    let serverText = Self.normalized(text)
    let completed = serverText.isEmpty ? Self.normalized(current) : serverText
    guard !completed.isEmpty else { return false }
    committedHistory.append(completed)
    if committedHistory.count > Self.maxHistorySegments {
      committedHistory.removeFirst(committedHistory.count - Self.maxHistorySegments)
    }
    current = ""
    return true
  }

  mutating func reset() {
    current = ""
    committedHistory = []
  }

  private static func normalized(_ text: String) -> String {
    text
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: { $0.isWhitespace })
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private static func join(_ lhs: String, _ rhs: String) -> String {
    guard let last = lhs.last, let first = rhs.first else {
      return lhs + rhs
    }

    let noSpaceBefore: Set<Character> = ["，", "。", "！", "？", "、", ",", ".", "!", "?", ";", "；", ":", "："]
    if noSpaceBefore.contains(first) || Self.isCJK(last) || Self.isCJK(first) {
      return lhs + rhs
    }

    return lhs + " " + rhs
  }

  private static func mergeOverlapping(_ lhs: String, _ rhs: String) -> String? {
    let maxOverlap = min(lhs.count, rhs.count)
    guard maxOverlap > 1 else { return nil }

    for length in stride(from: maxOverlap, through: 2, by: -1) {
      // Compare Substrings directly; materializing two Strings per iteration
      // allocated on every fragment merge.
      if lhs.suffix(length) == rhs.prefix(length) {
        return lhs + rhs.dropFirst(length)
      }
    }

    return nil
  }

  private static func isCJK(_ character: Character) -> Bool {
    character.unicodeScalars.contains { scalar in
      (0x4E00...0x9FFF).contains(scalar.value)
        || (0x3040...0x30FF).contains(scalar.value)
        || (0xAC00...0xD7AF).contains(scalar.value)
    }
  }
}
