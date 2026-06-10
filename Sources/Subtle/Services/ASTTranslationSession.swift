import Foundation

actor ASTTranslationSession: TranslationSession {
  private let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v4/ast/v2/translate")!
  private let resourceID = "volc.service_type.10053"

  private let apiKey: String
  private let sourceLanguage: String
  private let targetLanguage: String
  private let onEvent: @Sendable (TranslationEvent) async -> Void
  private let sessionID = UUID().uuidString
  private let connectionID = UUID().uuidString

  private var webSocket: URLSessionWebSocketTask?
  private var isOpen = false

  init(
    apiKey: String,
    sourceLanguage: String,
    targetLanguage: String,
    onEvent: @escaping @Sendable (TranslationEvent) async -> Void
  ) {
    self.apiKey = apiKey
    self.sourceLanguage = sourceLanguage
    self.targetLanguage = targetLanguage
    self.onEvent = onEvent
  }

  func start() async throws {
    var request = URLRequest(url: endpoint)
    request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
    request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
    request.setValue(connectionID, forHTTPHeaderField: "X-Api-Connect-Id")

    let task = URLSession.shared.webSocketTask(with: request)
    webSocket = task
    task.resume()
    isOpen = true

    let payload = ProtobufCodec.startSession(
      sessionID: sessionID,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    )
    do {
      try await task.send(.data(payload))
    } catch {
      // The start frame failed to send: tear down the resumed socket and reset
      // state instead of leaving an open, un-cancelled connection behind.
      isOpen = false
      task.cancel(with: .abnormalClosure, reason: nil)
      webSocket = nil
      throw error
    }
    Task { await receiveLoop() }
  }

  func sendAudio(_ data: Data) async {
    guard isOpen, let webSocket else { return }
    let payload = ProtobufCodec.audioChunk(sessionID: sessionID, data: data)
    do {
      try await webSocket.send(.data(payload))
    } catch {
      isOpen = false
      await onEvent(.failed("发送音频失败：\(error.localizedDescription)"))
    }
  }

  func finish() async {
    guard let webSocket else { return }
    if isOpen {
      let payload = ProtobufCodec.finishSession(sessionID: sessionID)
      try? await webSocket.send(.data(payload))
    }
    isOpen = false
    webSocket.cancel(with: .normalClosure, reason: nil)
  }

  private func receiveLoop() async {
    guard let webSocket else { return }

    while isOpen {
      do {
        let message = try await webSocket.receive()
        let data: Data
        switch message {
        case .data(let payload):
          data = payload
        case .string(let text):
          data = Data(text.utf8)
        @unknown default:
          continue
        }
        await handleResponse(ProtobufCodec.parseResponse(data))
      } catch {
        if isOpen {
          isOpen = false
          await onEvent(.failed("接收 AST 响应失败：\(error.localizedDescription)"))
        }
      }
    }
  }

  private func handleResponse(_ response: ASTResponse) async {
    switch response.event {
    case ASTEventCode.sessionStarted:
      await onEvent(.sessionStarted)
    case ASTEventCode.sourceSubtitleStart:
      await onEvent(.sourceSubtitleStart)
    case ASTEventCode.sourceSubtitleResponse:
      await onEvent(.sourceSubtitle(response.text))
    case ASTEventCode.sourceSubtitleEnd:
      await onEvent(.sourceSubtitleEnd(response.text))
    case ASTEventCode.translationSubtitleStart:
      await onEvent(.translatedSubtitleStart)
    case ASTEventCode.translationSubtitleResponse:
      await onEvent(.translatedSubtitle(response.text))
    case ASTEventCode.translationSubtitleEnd:
      await onEvent(.translatedSubtitleEnd(response.text))
    case ASTEventCode.usageResponse:
      await onEvent(.usage(response.text))
    case ASTEventCode.sessionFinished:
      isOpen = false
      await onEvent(.finished)
    case ASTEventCode.sessionFailed:
      isOpen = false
      let message = response.message.isEmpty ? "AST 会话失败" : response.message
      await onEvent(.failed(message))
    default:
      break
    }
  }
}
