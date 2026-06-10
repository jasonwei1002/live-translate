import Foundation

/// Realtime translation session against DashScope's
/// qwen3.5-livetranslate-flash-realtime WebSocket API (JSON events; protocol
/// reference: vendor-docs/qwen-api-readme.md). Configured text-only — subtitles render
/// locally and translated audio is never requested. The server's own VAD
/// segments utterances, so unlike AST there are no explicit subtitle-start
/// events; segment opens are synthesized before the first fragment.
actor QwenTranslationSession: TranslationSession {
  private let endpoint = URL(
    string: "wss://dashscope.aliyuncs.com/api-ws/v1/realtime?model=qwen3.5-livetranslate-flash-realtime"
  )!

  private let apiKey: String
  private let sourceLanguage: String
  private let targetLanguage: String
  private let onEvent: @Sendable (TranslationEvent) async -> Void

  private var webSocket: URLSessionWebSocketTask?
  private var isOpen = false
  private var startedSignaled = false
  private var sourceSegmentOpen = false
  private var translationSegmentOpen = false

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
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

    let task = URLSession.shared.webSocketTask(with: request)
    webSocket = task
    task.resume()
    isOpen = true

    let payload = QwenRealtimeCodec.sessionUpdate(
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    )
    do {
      try await task.send(.string(payload))
    } catch {
      // The config frame failed to send: tear down the resumed socket and
      // reset state instead of leaving an open, un-cancelled connection.
      isOpen = false
      task.cancel(with: .abnormalClosure, reason: nil)
      webSocket = nil
      throw error
    }
    Task { await receiveLoop() }
  }

  func sendAudio(_ data: Data) async {
    guard isOpen, let webSocket else { return }
    do {
      try await webSocket.send(.string(QwenRealtimeCodec.audioAppend(data)))
    } catch {
      isOpen = false
      await onEvent(.failed("发送音频失败：\(error.localizedDescription)"))
    }
  }

  func finish() async {
    guard let webSocket else { return }
    if isOpen {
      // Protocol-required close signal. Like the AST session, stop() is not
      // blocked on the server's session.finished acknowledgement; the last
      // in-flight utterance may be dropped, which manual stop accepts.
      try? await webSocket.send(.string(QwenRealtimeCodec.sessionFinish()))
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
        await handle(QwenRealtimeCodec.parseEvent(data))
      } catch {
        if isOpen {
          isOpen = false
          await onEvent(.failed("接收 Qwen 响应失败：\(error.localizedDescription)"))
        }
      }
    }
  }

  private func handle(_ event: QwenRealtimeCodec.ServerEvent) async {
    switch event.type {
    case "session.created", "session.updated":
      if !startedSignaled {
        startedSignaled = true
        await onEvent(.sessionStarted)
      }
    case "conversation.item.input_audio_transcription.text":
      // Carries the segment's confirmed+pending text cumulatively (the codec
      // joins text+stash); the assembler's prefix-extension merge absorbs it
      // like AST partials.
      await openSourceSegmentIfNeeded()
      if !event.text.isEmpty {
        await onEvent(.sourceSubtitle(event.text))
      }
    case "conversation.item.input_audio_transcription.completed":
      sourceSegmentOpen = false
      await onEvent(.sourceSubtitleEnd(event.text))
    case "response.created":
      await openTranslationSegmentIfNeeded()
    // Text-only modality streams increments as `response.text.text` (NOT the
    // OpenAI-style `.delta`); `response.audio_transcript.text` is the
    // audio-modality counterpart. Verified against live traffic and the
    // DashScope server-events doc.
    case "response.text.text", "response.audio_transcript.text":
      await openTranslationSegmentIfNeeded()
      if !event.text.isEmpty {
        await onEvent(.translatedSubtitle(event.text))
      }
    case "response.text.done", "response.audio_transcript.done":
      translationSegmentOpen = false
      await onEvent(.translatedSubtitleEnd(event.text))
    case "session.finished":
      isOpen = false
      await onEvent(.finished)
    case "error":
      isOpen = false
      let message = event.errorMessage.isEmpty ? "Qwen 会话失败" : event.errorMessage
      await onEvent(.failed(message))
    default:
      break
    }
  }

  private func openSourceSegmentIfNeeded() async {
    guard !sourceSegmentOpen else { return }
    sourceSegmentOpen = true
    await onEvent(.sourceSubtitleStart)
  }

  private func openTranslationSegmentIfNeeded() async {
    guard !translationSegmentOpen else { return }
    translationSegmentOpen = true
    await onEvent(.translatedSubtitleStart)
  }
}
