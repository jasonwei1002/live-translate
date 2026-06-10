import Foundation

/// JSON encoder/decoder for DashScope's qwen3.5-livetranslate-flash-realtime
/// WebSocket protocol (OpenAI-realtime-style events). Pure functions, playing
/// the role ProtobufCodec plays for the AST provider; the protocol reference
/// is vendor-docs/qwen-api-readme.md.
enum QwenRealtimeCodec {
  /// session.update configuring text-only output plus source-language ASR
  /// (qwen3-asr-flash-realtime), so the overlay can render 双语 subtitles
  /// without paying for synthesized audio the app would never play.
  static func sessionUpdate(sourceLanguage: String, targetLanguage: String) -> String {
    encode([
      "type": "session.update",
      "session": [
        "modalities": ["text"],
        "input_audio_format": "pcm",
        "input_audio_transcription": [
          "model": "qwen3-asr-flash-realtime",
          "language": sourceLanguage,
        ],
        "translation": [
          "language": targetLanguage
        ],
      ],
    ])
  }

  static func audioAppend(_ pcm: Data) -> String {
    // Hot path (~10 chunks/s): base64 output never needs JSON escaping, so the
    // frame is interpolated directly instead of paying for JSONSerialization.
    #"{"audio":"\#(pcm.base64EncodedString())","type":"input_audio_buffer.append"}"#
  }

  static func sessionFinish() -> String {
    encode(["type": "session.finish"])
  }

  /// Parsed server event: `type` plus the first text payload found among the
  /// field names DashScope uses across event kinds. Each event type carries at
  /// most one of these fields, so the scan order never mixes payloads.
  struct ServerEvent: Equatable {
    var type = ""
    var text = ""
    var errorMessage = ""
  }

  static func parseEvent(_ data: Data) -> ServerEvent {
    guard let object = try? JSONSerialization.jsonObject(with: data),
      let dict = object as? [String: Any]
    else {
      return ServerEvent()
    }

    var event = ServerEvent()
    event.type = dict["type"] as? String ?? ""
    // Rolling-text events carry confirmed + pending halves in `text`/`stash`;
    // joined they form the current provisional text. Other events use exactly
    // one of these fields, so the join degrades to that single value.
    let text = dict["text"] as? String ?? ""
    let stash = dict["stash"] as? String ?? ""
    if !text.isEmpty || !stash.isEmpty {
      event.text = text + stash
    } else {
      for key in ["delta", "transcript"] {
        if let value = dict[key] as? String, !value.isEmpty {
          event.text = value
          break
        }
      }
    }
    if let error = dict["error"] as? [String: Any],
      let message = error["message"] as? String {
      event.errorMessage = message
    } else if let message = dict["message"] as? String {
      event.errorMessage = message
    }
    return event
  }

  private static func encode(_ payload: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    else {
      return "{}"
    }
    return String(decoding: data, as: UTF8.self)
  }
}
