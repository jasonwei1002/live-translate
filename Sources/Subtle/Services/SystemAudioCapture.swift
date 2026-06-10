import AVFoundation
import CoreMedia
import Foundation
import os
@preconcurrency import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError {
  case noDisplay
  case audioFormatUnavailable
  case sampleBufferReadFailed(OSStatus)

  var errorDescription: String? {
    switch self {
    case .noDisplay:
      return "没有找到可捕获的显示器。"
    case .audioFormatUnavailable:
      return "无法读取系统音频格式。"
    case .sampleBufferReadFailed(let status):
      return "读取系统音频缓冲区失败，状态码 \(status)。"
    }
  }
}

final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
  private static let logger = Logger(subsystem: "com.local.Subtle", category: "capture")
  private let queue = DispatchQueue(label: "live-translate.system-audio")
  private let lock = NSLock()
  private var stream: SCStream?
  private var onPCM: (@Sendable (Data) -> Void)?
  /// Buffers delivered since start; only touched on `queue`.
  private var bufferCount = 0

  func start(onPCM: @escaping @Sendable (Data) -> Void) async throws {
    stop()
    lock.withLock { self.onPCM = onPCM }

    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: true
    )
    guard let display = content.displays.first else {
      throw SystemAudioCaptureError.noDisplay
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.capturesAudio = true
    configuration.excludesCurrentProcessAudio = true
    configuration.sampleRate = AudioFormat.sampleRate
    configuration.channelCount = AudioFormat.channelCount
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
    lock.withLock { self.stream = stream }
    try await stream.startCapture()
    queue.async { self.bufferCount = 0 }
    Self.logger.info("SCStream capture started")
  }

  func stop() {
    let stream: SCStream? = lock.withLock {
      let current = self.stream
      self.stream = nil
      self.onPCM = nil
      return current
    }
    if let stream {
      Task {
        try? await stream.stopCapture()
      }
    }
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of outputType: SCStreamOutputType
  ) {
    guard outputType == .audio, sampleBuffer.isValid else { return }
    let handler = lock.withLock { self.onPCM }
    guard let handler else { return }
    guard let pcm = try? PCMBufferExtractor.extractInt16Mono16k(from: sampleBuffer), !pcm.isEmpty else {
      return
    }
    // First buffer proves audio is flowing; periodic ticks keep --telemetry useful.
    if bufferCount == 0 || bufferCount % 500 == 0 {
      Self.logger.info("audio buffer #\(self.bufferCount), \(pcm.count) bytes")
    }
    bufferCount += 1
    handler(pcm)
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    Self.logger.error("SCStream stopped with error: \(error.localizedDescription)")
    // Only tear down if the failing stream is still the active one; a stale
    // stream from a previous session must not clobber a freshly started capture.
    let isCurrent = lock.withLock { self.stream === stream }
    guard isCurrent else { return }
    stop()
  }
}

private enum PCMBufferExtractor {
  static func extractInt16Mono16k(from sampleBuffer: CMSampleBuffer) throws -> Data {
    guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
          let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
      throw SystemAudioCaptureError.audioFormatUnavailable
    }

    let asbd = streamDescription.pointee
    let channelCount = max(1, Int(asbd.mChannelsPerFrame))
    let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
    guard frameCount > 0 else { return Data() }

    let audioBufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
    defer {
      audioBufferList.unsafeMutablePointer.deallocate()
    }

    var blockBuffer: CMBlockBuffer?
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: audioBufferList.unsafeMutablePointer,
      bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: channelCount),
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &blockBuffer
    )
    guard status == noErr else {
      throw SystemAudioCaptureError.sampleBufferReadFailed(status)
    }

    let monoFloat = extractMonoFloatSamples(
      from: audioBufferList,
      asbd: asbd,
      frameCount: frameCount,
      channelCount: channelCount
    )
    let resampled = resampleIfNeeded(
      monoFloat,
      sourceRate: asbd.mSampleRate,
      targetRate: Double(AudioFormat.sampleRate)
    )
    return int16PCM(from: resampled)
  }

  private static func extractMonoFloatSamples(
    from audioBufferList: UnsafeMutableAudioBufferListPointer,
    asbd: AudioStreamBasicDescription,
    frameCount: Int,
    channelCount: Int
  ) -> [Float] {
    let flags = asbd.mFormatFlags
    let isFloat = flags & kAudioFormatFlagIsFloat != 0
    let isSignedInteger = flags & kAudioFormatFlagIsSignedInteger != 0
    let isNonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
    let bytesPerSample = max(1, Int(asbd.mBitsPerChannel / 8))
    var samples = Array(repeating: Float(0), count: frameCount)

    if isNonInterleaved {
      let buffers = Array(audioBufferList)
      for channel in 0..<min(channelCount, buffers.count) {
        guard let data = buffers[channel].mData else { continue }
        accumulateChannel(
          data: data,
          into: &samples,
          frameCount: frameCount,
          channelCount: channelCount,
          bytesPerSample: bytesPerSample,
          isFloat: isFloat,
          isSignedInteger: isSignedInteger,
          stride: 1
        )
      }
      return samples
    }

    guard let firstBuffer = audioBufferList.first?.mData else { return samples }
    accumulateChannel(
      data: firstBuffer,
      into: &samples,
      frameCount: frameCount,
      channelCount: channelCount,
      bytesPerSample: bytesPerSample,
      isFloat: isFloat,
      isSignedInteger: isSignedInteger,
      stride: channelCount
    )
    return samples
  }

  private static func accumulateChannel(
    data: UnsafeMutableRawPointer,
    into samples: inout [Float],
    frameCount: Int,
    channelCount: Int,
    bytesPerSample: Int,
    isFloat: Bool,
    isSignedInteger: Bool,
    stride: Int
  ) {
    let channelsInBuffer = stride == 1 ? 1 : max(1, channelCount)
    let downmixScale = 1 / Float(max(1, channelCount))

    if isFloat && bytesPerSample == 4 {
      let pointer = data.bindMemory(to: Float.self, capacity: frameCount * stride)
      for frame in 0..<frameCount {
        var sum: Float = 0
        for channel in 0..<channelsInBuffer {
          sum += pointer[frame * stride + channel]
        }
        samples[frame] += sum * downmixScale
      }
      return
    }

    if isSignedInteger && bytesPerSample == 2 {
      let int16Scale = downmixScale / Float(Int16.max)
      let pointer = data.bindMemory(to: Int16.self, capacity: frameCount * stride)
      for frame in 0..<frameCount {
        var sum: Float = 0
        for channel in 0..<channelsInBuffer {
          sum += Float(pointer[frame * stride + channel])
        }
        samples[frame] += sum * int16Scale
      }
    }
  }

  private static func resampleIfNeeded(
    _ samples: [Float],
    sourceRate: Double,
    targetRate: Double
  ) -> [Float] {
    guard !samples.isEmpty, abs(sourceRate - targetRate) > 1 else { return samples }
    let outputCount = max(1, Int((Double(samples.count) * targetRate / sourceRate).rounded()))
    let step = sourceRate / targetRate
    let lastIndex = samples.count - 1
    // Linear interpolation between neighbouring source samples instead of
    // nearest-neighbour pick, which reduces resampling artifacts/aliasing.
    return (0..<outputCount).map { index in
      let position = Double(index) * step
      let lowerIndex = min(lastIndex, Int(position))
      let upperIndex = min(lastIndex, lowerIndex + 1)
      let fraction = Float(position - Double(lowerIndex))
      let lower = samples[lowerIndex]
      let upper = samples[upperIndex]
      return lower + (upper - lower) * fraction
    }
  }

  private static func int16PCM(from samples: [Float]) -> Data {
    // Convert into a contiguous Int16 buffer and wrap it in Data once; the
    // previous per-sample append paid a closure + tiny-append cost 16k times/s.
    var ints = [Int16](repeating: 0, count: samples.count)
    for index in samples.indices {
      let clipped = max(-1, min(1, samples[index]))
      ints[index] = Int16(clipped * Float(Int16.max)).littleEndian
    }
    return ints.withUnsafeBufferPointer { Data(buffer: $0) }
  }
}
