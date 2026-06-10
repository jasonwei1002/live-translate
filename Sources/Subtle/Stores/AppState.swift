import AppKit
import Foundation
import SwiftUI
import os

@MainActor
final class AppState: ObservableObject {
  nonisolated private static let logger = Logger(subsystem: "com.local.Subtle", category: "pipeline")
  // API keys are stored in UserDefaults by deliberate choice: Keychain storage
  // (one interim build) re-prompted for access after every ad-hoc rebuild,
  // which the user rejected. Not persisted on every keystroke; commit
  // explicitly via commitAPIKey() (on Settings submit and on start). One key
  // per provider, so switching providers never clobbers the other credential.
  @Published var volcanoAPIKey: String
  @Published var qwenAPIKey: String
  @Published var provider: TranslationProvider {
    didSet {
      defaults.set(provider.rawValue, forKey: TranslationProvider.defaultsKey)
      // A lingering test badge would misattribute the previous provider's
      // result to the newly selected one.
      connectionTestTask?.cancel()
      connectionTestState = .idle
      sanitizeLanguagesForProvider()
      // The new provider takes over immediately (user decision): a running
      // service is force-restarted instead of finishing on the old provider.
      if isRunning {
        stop()
        start()
      }
    }
  }
  @Published var sourceLanguage: String {
    didSet { defaults.set(sourceLanguage, forKey: Self.sourceLanguageKey) }
  }
  @Published var targetLanguage: String {
    didSet { defaults.set(targetLanguage, forKey: Self.targetLanguageKey) }
  }
  /// When false ("仅译文"), source-subtitle events are skipped entirely so they
  /// cannot contend for the publish throttle, keeping translation partials snappy.
  @Published var showSourceText: Bool {
    didSet { defaults.set(showSourceText, forKey: Self.showSourceTextKey) }
  }
  @Published var subtitleStyle: SubtitleStyle {
    didSet {
      defaults.set(subtitleStyle.rawValue, forKey: Self.subtitleStyleKey)
      pushAppearance()
    }
  }
  @Published var subtitleFontSize: Double {
    didSet {
      defaults.set(subtitleFontSize, forKey: Self.subtitleFontSizeKey)
      pushAppearance()
    }
  }
  @Published var subtitleOpacity: Double {
    didSet {
      defaults.set(subtitleOpacity, forKey: Self.subtitleOpacityKey)
      pushAppearance()
    }
  }
  /// Auto-stop the service after this many seconds of sustained silence
  /// (0 = never), so an idle connection is not kept open indefinitely.
  @Published var autoStopSilenceSeconds: Double {
    didSet { defaults.set(autoStopSilenceSeconds, forKey: Self.autoStopSilenceKey) }
  }

  @Published var statusText = "未启动"
  @Published var isRunning = false
  @Published var subtitle = SubtitleState()
  @Published var lastError: String?
  @Published var updateState: UpdateState = .idle
  /// Smoothed 0–1 input level for the menu-bar panel's level meter.
  @Published var audioLevel: Double = 0
  @Published var connectionTestState: ConnectionTestState = .idle

  enum ConnectionTestState: Equatable {
    case idle
    case testing
    case success(latencyMS: Int)
    case failed(String)
  }

  var subtitleAppearance: SubtitleAppearance {
    SubtitleAppearance(
      style: subtitleStyle,
      fontSize: subtitleFontSize,
      backgroundOpacity: subtitleOpacity
    )
  }

  var appVersion: String { AppUpdater.currentVersion }

  /// The selected provider's API key (not trimmed; trim before use).
  var activeAPIKey: String {
    switch provider {
    case .volcano: volcanoAPIKey
    case .qwen: qwenAPIKey
    }
  }

  private static let sourceLanguageKey = "sourceLanguage"
  private static let targetLanguageKey = "targetLanguage"
  private static let showSourceTextKey = "showSourceText"
  private static let subtitleStyleKey = "subtitleStyle"
  private static let subtitleFontSizeKey = "subtitleFontSize"
  private static let subtitleOpacityKey = "subtitleOpacity"
  private static let autoStopSilenceKey = "autoStopSilenceSeconds"

  private let defaults = UserDefaults.standard
  private let overlayController = SubtitleOverlayController()
  private let audioCapture = SystemAudioCapture()
  private var translationSession: (any TranslationSession)?
  private var audioStreamContinuation: AsyncStream<Data>.Continuation?
  private var audioPumpTask: Task<Void, Never>?
  // Budgets sized to the overlay: translation renders at 30pt (~28 CJK chars
  // per line, 3 lines), source at 17pt (~2 wider lines).
  private var sourceAssembler = StreamingSubtitleAssembler(displayCharacterBudget: 160)
  private var translatedAssembler = StreamingSubtitleAssembler(displayCharacterBudget: 100)
  private var subtitleUpdateTask: Task<Void, Never>?
  private var lastSubtitleUpdate = Date.distantPast
  private let minimumSubtitleUpdateInterval: TimeInterval = 0.35
  private var updateResetTask: Task<Void, Never>?
  private var connectionTestTask: Task<Void, Never>?
  private var overlayErrorHideTask: Task<Void, Never>?
  private var lastVoicedAt = Date()

  init() {
    LegacyDefaultsMigrator.migrateIfNeeded()
    let defaults = UserDefaults.standard
    self.provider = TranslationProvider.loadSelected(from: defaults)
    self.volcanoAPIKey =
      defaults.string(forKey: TranslationProvider.volcano.apiKeyDefaultsKey) ?? ""
    self.qwenAPIKey =
      defaults.string(forKey: TranslationProvider.qwen.apiKeyDefaultsKey) ?? ""
    self.sourceLanguage = defaults.string(forKey: Self.sourceLanguageKey) ?? "en"
    self.targetLanguage = defaults.string(forKey: Self.targetLanguageKey) ?? "zh"
    self.showSourceText = defaults.bool(forKey: Self.showSourceTextKey, default: true)
    self.subtitleStyle = defaults.string(forKey: Self.subtitleStyleKey)
      .flatMap(SubtitleStyle.init(rawValue:)) ?? .darkBar
    self.subtitleFontSize = defaults.object(forKey: Self.subtitleFontSizeKey) as? Double ?? 24
    self.subtitleOpacity = defaults.object(forKey: Self.subtitleOpacityKey) as? Double ?? 0.62
    self.autoStopSilenceSeconds =
      defaults.object(forKey: Self.autoStopSilenceKey) as? Double ?? 30
    overlayController.update(subtitle: subtitle)
    pushAppearance()
    // The overlay follows run state (no standalone switch), so it stays hidden
    // until translation starts; this also avoids an idle click-catching panel.
    overlayController.setVisible(false)
    // Persisted languages may predate a provider switch or a language-set
    // change; never present a picker whose selection is not in its options.
    sanitizeLanguagesForProvider()
  }

  private func pushAppearance() {
    overlayController.update(appearance: subtitleAppearance)
  }

  func start() {
    guard !isRunning else { return }
    let trimmedKey = activeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      lastError = "请先在「设置…」（⌘,）中填写 \(provider.shortTitle) API Key。"
      statusText = "缺少 API Key"
      return
    }
    if let languageError = provider.languagePairError(
      source: sourceLanguage, target: targetLanguage
    ) {
      lastError = languageError
      statusText = "语言设置无效"
      return
    }
    defaults.set(trimmedKey, forKey: provider.apiKeyDefaultsKey)

    overlayErrorHideTask?.cancel()
    lastError = nil
    // Listening placeholder until the first subtitle arrives, so an open but
    // silent session is visibly alive instead of an invisible overlay.
    var initialState = SubtitleState()
    initialState.isListening = true
    subtitle = initialState
    resetSubtitleAssembly()
    teardownAudioPump()
    overlayController.update(subtitle: subtitle)
    statusText = "正在连接 \(provider.shortTitle)..."
    isRunning = true
    lastVoicedAt = Date()
    // 字幕跟随服务: the overlay appears with the session and disappears with
    // it — there is no standalone subtitle switch (design decision).
    overlayController.setVisible(true)

    let session = TranslationSessionFactory.make(
      provider: provider,
      apiKey: trimmedKey,
      sourceLanguage: sourceLanguage,
      targetLanguage: targetLanguage
    ) { [weak self] event in
      await self?.handle(event)
    }
    translationSession = session

    // Feed captured PCM through an ordered AsyncStream so a single consumer
    // sends chunks to AST strictly in capture order. Spawning one Task per
    // chunk previously let sends reorder and corrupt the audio stream.
    let (audioStream, continuation) = AsyncStream<Data>.makeStream()
    audioStreamContinuation = continuation
    audioPumpTask = Task {
      await Self.pumpAudio(audioStream, to: session)
    }

    Task {
      do {
        try await session.start()
        // Throttle on the capture thread so we do not spawn a main-actor Task
        // per PCM buffer (50–100/s) just to discard most of them.
        let levelThrottle = LevelThrottle()
        try await audioCapture.start { [weak self] pcm in
          continuation.yield(pcm)
          guard levelThrottle.shouldEmit() else { return }
          // Cheap strided RMS so the panel meter tracks real input level.
          let level = Self.normalizedLevel(of: pcm)
          Task { @MainActor in
            self?.ingestAudioLevel(level)
          }
        }
        await MainActor.run {
          self.statusText = "正在捕获系统音频"
        }
      } catch {
        await MainActor.run {
          self.fail("启动失败：\(error.localizedDescription)")
        }
      }
    }
  }

  func stop() {
    guard isRunning else { return }
    statusText = "正在停止..."
    isRunning = false
    audioLevel = 0
    audioCapture.stop()
    let session = translationSession
    translationSession = nil
    teardownAudioPump()
    resetSubtitleAssembly()
    hideOverlayPanel()

    Task {
      await session?.finish()
      await MainActor.run {
        // A provider switch may have restarted the service while the old
        // session was finishing; don't overwrite the new session's status.
        if !self.isRunning {
          self.statusText = "已停止"
        }
      }
    }
  }

  private func hideOverlayPanel() {
    overlayController.setVisible(false)
  }

  /// Mirrors SilenceGate's ≈ -40 dBFS voice threshold on the meter's 0–1 scale.
  private static let voicedLevelThreshold = 0.2

  /// Main-actor sink for (already throttled) capture-thread level samples.
  /// Also drives auto-stop: sustained silence past the configured timeout
  /// stops the service instead of keeping an idle connection open.
  private func ingestAudioLevel(_ level: Double) {
    guard isRunning else { return }
    // Fast attack, slow decay, so speech pauses fall back smoothly.
    audioLevel = max(level, audioLevel * 0.65)
    if level >= Self.voicedLevelThreshold {
      lastVoicedAt = Date()
    } else if autoStopSilenceSeconds > 0,
      Date().timeIntervalSince(lastVoicedAt) >= autoStopSilenceSeconds {
      stop()
      lastError = "持续 \(Int(autoStopSilenceSeconds)) 秒无声音，已自动停止服务。"
    }
  }

  /// Maps raw 16-bit PCM to a 0–1 meter value via strided RMS in dBFS.
  private nonisolated static func normalizedLevel(of pcm: Data) -> Double {
    guard pcm.count >= 2 else { return 0 }
    var sum = 0.0
    var count = 0
    pcm.withUnsafeBytes { raw in
      let samples = raw.bindMemory(to: Int16.self)
      let step = max(1, samples.count / 256)
      var index = 0
      while index < samples.count {
        let value = Double(samples[index]) / 32768
        sum += value * value
        count += 1
        index += step
      }
    }
    guard count > 0 else { return 0 }
    let rms = (sum / Double(count)).squareRoot()
    guard rms > 0 else { return 0 }
    let db = 20 * log10(rms)
    return min(1, max(0, (db + 50) / 50))
  }

  /// Verifies the selected provider's API key with a short-lived session
  /// (start → started → finish). Uses a fixed en→zh pair so the result
  /// reflects the credential, not the user's current language combination.
  func testConnection() {
    if case .testing = connectionTestState { return }
    let trimmedKey = activeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      connectionTestState = .failed("请先填写 API Key。")
      return
    }
    commitAPIKey()
    connectionTestState = .testing
    connectionTestTask?.cancel()
    connectionTestTask = Task { [weak self, provider] in
      let started = Date()
      let (events, continuation) = AsyncStream<TranslationEvent>.makeStream()
      let session = TranslationSessionFactory.make(
        provider: provider,
        apiKey: trimmedKey,
        sourceLanguage: "en",
        targetLanguage: "zh"
      ) { event in
        continuation.yield(event)
      }

      var result = ConnectionTestState.failed("连接超时，请检查网络后重试。")
      do {
        try await session.start()
        let timeout = Task {
          try? await Task.sleep(nanoseconds: 8_000_000_000)
          continuation.finish()
        }
        loop: for await event in events {
          switch event {
          case .sessionStarted:
            result = .success(latencyMS: Int(Date().timeIntervalSince(started) * 1000))
            break loop
          case .failed(let message):
            result = .failed(message)
            break loop
          default:
            continue
          }
        }
        timeout.cancel()
      } catch {
        result = .failed("连接失败：\(error.localizedDescription)")
      }
      // Idempotent; releases the stream so late session events drop cleanly.
      continuation.finish()
      await session.finish()

      guard !Task.isCancelled, let self else { return }
      await MainActor.run {
        self.connectionTestState = result
        if case .success = result {
          self.scheduleConnectionTestReset()
        }
      }
    }
  }

  /// Reverts a "连接成功" badge back to idle after a moment, mirroring the
  /// design's state flow; failures stay visible until the next attempt.
  private func scheduleConnectionTestReset() {
    Task { [weak self] in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard let self, case .success = self.connectionTestState else { return }
      self.connectionTestState = .idle
    }
  }

  /// Swaps source/target languages. Takes effect on the next session start;
  /// a running session keeps the languages it connected with. No-op when the
  /// swap would be invalid (e.g. an AST dialect is source-only).
  func swapLanguages() {
    guard provider.targetLanguageIDs.contains(sourceLanguage),
      provider.sourceLanguageIDs.contains(targetLanguage) else { return }
    (sourceLanguage, targetLanguage) = (targetLanguage, sourceLanguage)
  }

  /// Keeps the persisted language pair valid for the selected provider (each
  /// provider has its own language set per its protocol doc): unsupported
  /// codes fall back to en→zh defaults without ever leaving source == target.
  private func sanitizeLanguagesForProvider() {
    if !provider.sourceLanguageIDs.contains(sourceLanguage) {
      sourceLanguage = "en"
    }
    if !provider.targetLanguageIDs.contains(targetLanguage) || targetLanguage == sourceLanguage {
      targetLanguage = sourceLanguage == "zh" ? "en" : "zh"
    }
  }

  func setShowSourceText(_ show: Bool) {
    showSourceText = show
    if !show {
      sourceAssembler.reset()
    }
    updateDisplayedSubtitle()
  }

  func commitAPIKey() {
    defaults.set(volcanoAPIKey, forKey: TranslationProvider.volcano.apiKeyDefaultsKey)
    defaults.set(qwenAPIKey, forKey: TranslationProvider.qwen.apiKeyDefaultsKey)
  }

  func checkForUpdates(manual: Bool) {
    switch updateState {
    case .checking, .downloading, .installing: return
    default: break
    }
    updateResetTask?.cancel()
    updateState = .checking
    Task {
      do {
        if let info = try await AppUpdater.checkForUpdate() {
          updateState = .available(info)   // sticky: user must act on it
        } else {
          updateState = .upToDate
          scheduleUpdateStateReset()
        }
      } catch {
        // A silent (non-manual) check that fails should not nag the user.
        updateState = manual ? .failed("检查更新失败：\(error.localizedDescription)") : .idle
        if manual { scheduleUpdateStateReset() }
      }
    }
  }

  /// Revert a terminal "已是最新 / 失败" badge back to the plain "检查更新"
  /// button after a short delay, so the header does not stay in a result state.
  private func scheduleUpdateStateReset() {
    updateResetTask?.cancel()
    updateResetTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard !Task.isCancelled, let self else { return }
      switch self.updateState {
      case .upToDate, .failed: self.updateState = .idle
      default: break
      }
    }
  }

  func installUpdate() {
    guard case .available(let info) = updateState else { return }
    updateState = .downloading(0)
    Task {
      do {
        let dmg = try await AppUpdater.download(info) { [weak self] fraction in
          Task { @MainActor in
            // Ignore late ticks once we have moved past downloading.
            if case .downloading = self?.updateState {
              self?.updateState = .downloading(fraction)
            }
          }
        }
        updateState = .installing
        // installAndRelaunch terminates the process on success; reaching the
        // next line means the swap failed before handing off to the helper.
        try await AppUpdater.installAndRelaunch(dmgPath: dmg)
      } catch {
        updateState = .failed("更新失败：\(error.localizedDescription)")
      }
    }
  }

  private func teardownAudioPump() {
    audioStreamContinuation?.finish()
    audioStreamContinuation = nil
    audioPumpTask?.cancel()
    audioPumpTask = nil
  }

  private nonisolated static func pumpAudio(
    _ stream: AsyncStream<Data>,
    to session: any TranslationSession
  ) async {
    let chunkSize = AudioFormat.chunkByteCount
    var buffer = Data()
    // Drop sustained silence before it reaches AST: quiet periods otherwise
    // consume billed translation time for nothing.
    var silenceGate = SilenceGate()
    var sentChunks = 0
    for await pcm in stream {
      guard let gated = silenceGate.process(pcm) else { continue }
      buffer.append(gated)
      // Slice by offset and compact once per incoming buffer; removeFirst per
      // chunk re-shifted the whole remainder on every iteration.
      var offset = 0
      while buffer.count - offset >= chunkSize {
        let chunk = buffer.subdata(in: offset..<(offset + chunkSize))
        offset += chunkSize
        await session.sendAudio(chunk)
        sentChunks += 1
        if sentChunks == 1 || sentChunks % 100 == 0 {
          logger.info("pump sent chunk #\(sentChunks)")
        }
      }
      if offset > 0 {
        buffer.removeSubrange(0..<offset)
      }
    }
  }

  private func handle(_ event: TranslationEvent) async {
    Self.logger.info("event: \(String(describing: event).prefix(48), privacy: .public)")
    switch event {
    case .sessionStarted:
      statusText = "翻译服务已连接"
    case .sourceSubtitleStart:
      guard showSourceText else { return }
      sourceAssembler.beginSegment()
    case .sourceSubtitle(let text):
      guard showSourceText else { return }
      if sourceAssembler.ingest(text) {
        publishSubtitle(force: false)
      }
    case .sourceSubtitleEnd(let text):
      guard showSourceText else { return }
      if sourceAssembler.endSegment(authoritative: text) {
        publishSubtitle(force: true)
      }
    case .translatedSubtitleStart:
      translatedAssembler.beginSegment()
    case .translatedSubtitle(let text):
      if translatedAssembler.ingest(text) {
        publishSubtitle(force: false)
      }
    case .translatedSubtitleEnd(let text):
      if translatedAssembler.endSegment(authoritative: text) {
        publishSubtitle(force: true)
      }
    case .usage:
      break
    case .finished:
      statusText = "会话已结束"
      isRunning = false
      audioLevel = 0
      audioCapture.stop()
      teardownAudioPump()
      closeSession()
      hideOverlayPanel()
    case .failed(let message):
      fail(message)
    }
  }

  private func fail(_ message: String) {
    lastError = message
    statusText = "出错"
    isRunning = false
    audioLevel = 0
    audioCapture.stop()
    teardownAudioPump()
    closeSession()
    // Surface the failure on the overlay for a moment before hiding it;
    // hiding immediately read as "nothing happened" since the menu-bar panel
    // is usually closed when a session dies.
    var errorState = SubtitleState()
    errorState.errorText = message
    subtitle = errorState
    overlayController.update(subtitle: subtitle)
    overlayErrorHideTask?.cancel()
    overlayErrorHideTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 4_000_000_000)
      guard !Task.isCancelled, let self, !self.isRunning else { return }
      self.hideOverlayPanel()
    }
  }

  /// Immediately tears down the translation session so a failed or finished
  /// run never leaves the WebSocket open (an idle connection still bills time).
  private func closeSession() {
    let session = translationSession
    translationSession = nil
    Task {
      await session?.finish()
    }
  }

  private func publishSubtitle(force: Bool) {
    if force || Date().timeIntervalSince(lastSubtitleUpdate) >= minimumSubtitleUpdateInterval {
      updateDisplayedSubtitle()
      return
    }

    subtitleUpdateTask?.cancel()
    let delay = minimumSubtitleUpdateInterval - Date().timeIntervalSince(lastSubtitleUpdate)
    subtitleUpdateTask = Task { [weak self] in
      let nanoseconds = UInt64(max(0.05, delay) * 1_000_000_000)
      try? await Task.sleep(nanoseconds: nanoseconds)
      guard !Task.isCancelled else { return }
      await MainActor.run {
        self?.updateDisplayedSubtitle()
      }
    }
  }

  private func updateDisplayedSubtitle() {
    // Source shows only the active sentence (small companion line); the
    // translation rolls as independent lines so committed text never reflows.
    subtitle.sourceText = showSourceText ? (sourceAssembler.displayLines.last ?? "") : ""
    subtitle.translatedLines = translatedAssembler.displayLines
    subtitle.errorText = ""
    subtitle.isListening = subtitle.hasText ? false : isRunning
    subtitle.lastUpdated = Date()
    lastSubtitleUpdate = subtitle.lastUpdated
    overlayController.update(subtitle: subtitle)
  }

  private func resetSubtitleAssembly() {
    sourceAssembler.reset()
    translatedAssembler.reset()
    subtitleUpdateTask?.cancel()
    subtitleUpdateTask = nil
  }
}

/// Lock-protected rate limiter usable from the @Sendable capture callback,
/// so level samples are dropped *before* paying for a main-actor Task hop.
private final class LevelThrottle: @unchecked Sendable {
  private let lock = NSLock()
  private var last = Date.distantPast

  func shouldEmit(interval: TimeInterval = 0.1) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let now = Date()
    guard now.timeIntervalSince(last) >= interval else { return false }
    last = now
    return true
  }
}

private extension UserDefaults {
  /// Reads a Bool, returning `defaultValue` when the key was never set (instead
  /// of the silent `false` that `bool(forKey:)` returns for a missing key).
  func bool(forKey key: String, default defaultValue: Bool) -> Bool {
    object(forKey: key) == nil ? defaultValue : bool(forKey: key)
  }
}
