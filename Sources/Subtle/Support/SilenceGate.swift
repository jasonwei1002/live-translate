import Foundation

/// Energy-based gate that suppresses audio sent to AST during sustained
/// silence, so quiet periods do not consume billed translation time.
///
/// Time is measured in audio duration (16 kHz / 16-bit LE / mono), not wall
/// clock, which keeps the logic deterministic and unit-testable. Behavior:
/// - voiced audio always passes;
/// - silence keeps passing for `hangover` seconds so sentence tails and short
///   pauses are not clipped;
/// - past the hangover the gate closes: silent buffers are dropped, except a
///   short all-zero keepalive every `keepaliveInterval` so the AST connection
///   does not idle out;
/// - while closed, the last `preRoll` seconds are retained and prepended when
///   voice resumes, so soft onsets are not clipped.
struct SilenceGate {
  struct Config {
    /// RMS threshold as a fraction of Int16 full scale (default ≈ -40 dBFS).
    var rmsThreshold: Float = 0.01
    var hangover: TimeInterval = 2.0
    var preRoll: TimeInterval = 0.3
    /// Must stay well under AST's server-side packet timeout (~10 s observed:
    /// "[Timeout waiting next packet]" kills the session) — 5 s keeps the
    /// connection alive while billing only 2% of silent time.
    var keepaliveInterval: TimeInterval = 5.0
    /// 0.1 s at 16 kHz/16-bit is exactly one 3200-byte AST chunk.
    var keepaliveDuration: TimeInterval = 0.1
  }

  private let config: Config
  private var trailingSilence: TimeInterval = 0
  // Keepalive pacing and pre-roll are counted in bytes, not seconds:
  // accumulating Double durations drifts (50 × 0.1 < 5.0) and silently
  // skips keepalives / over-trims the retained pre-roll.
  private var silentBytesSinceKeepalive = 0
  private let keepaliveIntervalBytes: Int
  private var preRollBuffers: [Data] = []
  private var preRollBytes = 0
  private let preRollByteLimit: Int

  init(config: Config = Config()) {
    self.config = config
    self.preRollByteLimit = Int(config.preRoll * Double(AudioFormat.bytesPerSecond))
    self.keepaliveIntervalBytes = Int(config.keepaliveInterval * Double(AudioFormat.bytesPerSecond))
  }

  /// Feeds one PCM buffer; returns the bytes to forward to AST (possibly with
  /// pre-roll prepended), or nil when the buffer should be suppressed.
  mutating func process(_ pcm: Data) -> Data? {
    let duration = Self.duration(of: pcm)
    guard duration > 0 else { return nil }

    if Self.rms(of: pcm) >= config.rmsThreshold {
      trailingSilence = 0
      silentBytesSinceKeepalive = 0
      guard !preRollBuffers.isEmpty else { return pcm }
      var output = Data(capacity: preRollBytes + pcm.count)
      for buffered in preRollBuffers {
        output.append(buffered)
      }
      output.append(pcm)
      clearPreRoll()
      return output
    }

    trailingSilence += duration
    if trailingSilence <= config.hangover {
      return pcm
    }

    appendPreRoll(pcm)
    silentBytesSinceKeepalive += pcm.count
    if silentBytesSinceKeepalive >= keepaliveIntervalBytes {
      silentBytesSinceKeepalive = 0
      return Data(count: Int(config.keepaliveDuration * Double(AudioFormat.bytesPerSecond)))
    }
    return nil
  }

  private mutating func appendPreRoll(_ pcm: Data) {
    preRollBuffers.append(pcm)
    preRollBytes += pcm.count
    while preRollBytes > preRollByteLimit, !preRollBuffers.isEmpty {
      preRollBytes -= preRollBuffers.removeFirst().count
    }
  }

  private mutating func clearPreRoll() {
    preRollBuffers.removeAll()
    preRollBytes = 0
  }

  private static func duration(of pcm: Data) -> TimeInterval {
    TimeInterval(pcm.count / AudioFormat.bytesPerSample) / TimeInterval(AudioFormat.sampleRate)
  }

  private static func rms(of pcm: Data) -> Float {
    let sampleCount = pcm.count / AudioFormat.bytesPerSample
    guard sampleCount > 0 else { return 0 }
    // Float throughout: this runs on every captured buffer, and Float precision
    // is ample for a threshold comparison over normalized samples.
    var sumSquares: Float = 0
    pcm.withUnsafeBytes { raw in
      for sampleIndex in 0..<sampleCount {
        let sample = raw.loadUnaligned(fromByteOffset: sampleIndex * AudioFormat.bytesPerSample, as: Int16.self)
        let normalized = Float(Int16(littleEndian: sample)) / Float(Int16.max)
        sumSquares += normalized * normalized
      }
    }
    return (sumSquares / Float(sampleCount)).squareRoot()
  }
}
