import Foundation

enum ASTEventCode {
  static let startSession = 100
  static let finishSession = 102
  static let sessionStarted = 150
  static let sessionFinished = 152
  static let sessionFailed = 153
  static let usageResponse = 154
  static let taskRequest = 200
  static let sourceSubtitleStart = 650
  static let sourceSubtitleResponse = 651
  static let sourceSubtitleEnd = 652
  static let translationSubtitleStart = 653
  static let translationSubtitleResponse = 654
  static let translationSubtitleEnd = 655
}

struct ASTResponse {
  var event = 0
  var sessionID = ""
  var sequence = 0
  var statusCode = 0
  var message = ""
  var text = ""
  var data = Data()
}

enum ProtobufCodec {
  static func startSession(
    sessionID: String,
    sourceLanguage: String,
    targetLanguage: String
  ) -> Data {
    var data = Data()
    data.appendMessage(field: 1, requestMeta(sessionID: sessionID))
    data.appendVarint(field: 2, UInt64(ASTEventCode.startSession))
    data.appendMessage(field: 3, user)
    data.appendMessage(field: 4, sourceAudio(binaryData: nil))
    data.appendMessage(field: 5, targetAudio())
    data.appendMessage(
      field: 6,
      requestParams(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    )
    return data
  }

  static func audioChunk(sessionID: String, data pcm: Data) -> Data {
    var data = Data()
    data.appendMessage(field: 1, requestMeta(sessionID: sessionID))
    data.appendVarint(field: 2, UInt64(ASTEventCode.taskRequest))
    data.appendMessage(field: 3, user)
    data.appendMessage(field: 4, sourceAudio(binaryData: pcm))
    return data
  }

  static func finishSession(sessionID: String) -> Data {
    var data = Data()
    data.appendMessage(field: 1, requestMeta(sessionID: sessionID))
    data.appendVarint(field: 2, UInt64(ASTEventCode.finishSession))
    data.appendMessage(field: 3, user)
    data.appendMessage(field: 4, sourceAudio(binaryData: nil))
    return data
  }

  static func parseResponse(_ data: Data) -> ASTResponse {
    var response = ASTResponse()
    let fields = parseFields(data)
    for field in fields {
      switch field.number {
      case 1:
        parseResponseMeta(field.data, into: &response)
      case 2:
        response.event = Int(field.varint ?? 0)
      case 3:
        response.data = field.data
      case 4:
        response.text = String(data: field.data, encoding: .utf8) ?? ""
      default:
        continue
      }
    }
    return response
  }

  private static func requestMeta(sessionID: String) -> Data {
    var data = Data()
    data.appendString(field: 6, sessionID)
    return data
  }

  // Built once: audioChunk() runs ~10x/s and Host.current().localizedName is a
  // non-trivial system lookup that must not sit on the audio send path.
  private static let user: Data = {
    var data = Data()
    data.appendString(field: 1, "live_translate_mac")
    data.appendString(field: 2, Host.current().localizedName ?? "mac")
    data.appendString(field: 3, "macOS")
    data.appendString(field: 4, "0.1.0")
    return data
  }()

  private static func sourceAudio(binaryData: Data?) -> Data {
    var data = Data()
    data.appendString(field: 4, "wav")
    data.appendString(field: 5, "raw")
    data.appendVarint(field: 7, UInt64(AudioFormat.sampleRate))
    data.appendVarint(field: 8, UInt64(AudioFormat.bitsPerSample))
    data.appendVarint(field: 9, UInt64(AudioFormat.channelCount))
    if let binaryData, !binaryData.isEmpty {
      data.appendBytes(field: 14, binaryData)
    }
    return data
  }

  private static func targetAudio() -> Data {
    var data = Data()
    data.appendString(field: 4, "ogg_opus")
    data.appendVarint(field: 7, 24_000)
    return data
  }

  private static func requestParams(sourceLanguage: String, targetLanguage: String) -> Data {
    var data = Data()
    data.appendString(field: 1, "s2t")
    data.appendString(field: 2, sourceLanguage)
    data.appendString(field: 3, targetLanguage)
    return data
  }

  private static func parseResponseMeta(_ data: Data, into response: inout ASTResponse) {
    for field in parseFields(data) {
      switch field.number {
      case 1:
        response.sessionID = String(data: field.data, encoding: .utf8) ?? ""
      case 2:
        response.sequence = Int(field.varint ?? 0)
      case 3:
        response.statusCode = Int(field.varint ?? 0)
      case 4:
        response.message = String(data: field.data, encoding: .utf8) ?? ""
      default:
        continue
      }
    }
  }
}

private struct ProtoField {
  var number: Int
  var wireType: UInt8
  var data: Data
  var varint: UInt64?
}

private func parseFields(_ data: Data) -> [ProtoField] {
  let bytes = [UInt8](data)
  var index = 0
  var fields: [ProtoField] = []

  while index < bytes.count {
    guard let key = readVarint(bytes, index: &index) else { break }
    let number = Int(key >> 3)
    let wireType = UInt8(key & 0x7)

    switch wireType {
    case 0:
      guard let value = readVarint(bytes, index: &index) else { return fields }
      fields.append(ProtoField(number: number, wireType: wireType, data: Data(), varint: value))
    case 2:
      guard let length = readVarint(bytes, index: &index) else { return fields }
      // Guard against overflow/out-of-bounds before converting to Int: a hostile
      // or malformed length varint must not trap the process.
      guard length <= UInt64(bytes.count - index) else { return fields }
      let end = index + Int(length)
      fields.append(ProtoField(number: number, wireType: wireType, data: Data(bytes[index..<end]), varint: nil))
      index = end
    case 1:
      // 64-bit fixed field: skip its 8 bytes so later fields stay parseable
      // instead of aborting the whole message.
      guard bytes.count - index >= 8 else { return fields }
      index += 8
    case 5:
      // 32-bit fixed field: skip its 4 bytes.
      guard bytes.count - index >= 4 else { return fields }
      index += 4
    default:
      return fields
    }
  }

  return fields
}

private func readVarint(_ bytes: [UInt8], index: inout Int) -> UInt64? {
  var shift: UInt64 = 0
  var result: UInt64 = 0

  while index < bytes.count && shift < 64 {
    let byte = bytes[index]
    index += 1
    result |= UInt64(byte & 0x7f) << shift
    if byte & 0x80 == 0 {
      return result
    }
    shift += 7
  }

  return nil
}

private extension Data {
  mutating func appendVarint(field: Int, _ value: UInt64) {
    appendRawVarint(UInt64(field << 3))
    appendRawVarint(value)
  }

  mutating func appendString(field: Int, _ value: String) {
    appendBytes(field: field, Data(value.utf8))
  }

  mutating func appendMessage(field: Int, _ value: Data) {
    appendBytes(field: field, value)
  }

  mutating func appendBytes(field: Int, _ value: Data) {
    appendRawVarint(UInt64((field << 3) | 2))
    appendRawVarint(UInt64(value.count))
    append(value)
  }

  mutating func appendRawVarint(_ value: UInt64) {
    var value = value
    while value >= 0x80 {
      append(UInt8(value & 0x7f) | 0x80)
      value >>= 7
    }
    append(UInt8(value))
  }
}
