import Foundation

/// Common surface of a realtime translation session, so AppState drives either
/// provider through the same audio pump, event handling, and teardown paths.
protocol TranslationSession: Actor {
  func start() async throws
  func sendAudio(_ data: Data) async
  func finish() async
}

enum TranslationSessionFactory {
  static func make(
    provider: TranslationProvider,
    apiKey: String,
    sourceLanguage: String,
    targetLanguage: String,
    onEvent: @escaping @Sendable (TranslationEvent) async -> Void
  ) -> any TranslationSession {
    switch provider {
    case .volcano:
      ASTTranslationSession(
        apiKey: apiKey,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        onEvent: onEvent
      )
    case .qwen:
      QwenTranslationSession(
        apiKey: apiKey,
        sourceLanguage: sourceLanguage,
        targetLanguage: targetLanguage,
        onEvent: onEvent
      )
    }
  }
}
