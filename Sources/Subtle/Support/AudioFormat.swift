import Foundation

/// Single source of truth for the AST audio contract (16 kHz / 16-bit / mono
/// little-endian PCM). Every layer that captures, gates, encodes, or chunks
/// audio must derive from these constants instead of re-declaring them.
enum AudioFormat {
  static let sampleRate = 16_000
  static let bitsPerSample = 16
  static let channelCount = 1

  static var bytesPerSample: Int { bitsPerSample / 8 }
  static var bytesPerSecond: Int { sampleRate * bytesPerSample * channelCount }
  /// 0.1 s of audio — the chunk size sent to AST.
  static var chunkByteCount: Int { bytesPerSecond / 10 }
}
