import Foundation

enum TranslationEvent: Equatable {
  case sessionStarted
  case sourceSubtitleStart
  case sourceSubtitle(String)
  case sourceSubtitleEnd(String)
  case translatedSubtitleStart
  case translatedSubtitle(String)
  case translatedSubtitleEnd(String)
  case usage(String)
  case finished
  case failed(String)
}
