import AppKit
import Foundation

/// A newer release discovered on GitHub Releases.
struct UpdateInfo: Equatable, Sendable {
  let version: String       // normalized, e.g. "0.2.0"
  let tag: String           // raw tag, e.g. "v0.2.0"
  let releaseNotes: String
  let downloadURL: URL
  let assetSize: Int64
}

/// UI-facing state machine for the in-app updater. Owned by `AppState`.
enum UpdateState: Equatable, Sendable {
  case idle
  case checking
  case upToDate
  case available(UpdateInfo)
  case downloading(Double)   // 0...1
  case installing
  case failed(String)
}

/// Zero-dependency in-app updater. Queries GitHub Releases for the latest DMG,
/// downloads it, then swaps the running `.app` bundle in place via a detached
/// helper script and relaunches. No Sparkle / third-party packages by design.
enum AppUpdater {
  /// GitHub repository to check, as "owner/repo".
  static let repository = "jasonwei1002/Subtle"

  static var currentVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
  }

  enum UpdaterError: LocalizedError {
    case notConfigured
    case badResponse
    case mountFailed
    case appNotFoundInDMG
    case copyFailed

    var errorDescription: String? {
      switch self {
      case .notConfigured: return "尚未配置 GitHub 仓库（AppUpdater.repository）。"
      case .badResponse: return "无法连接 GitHub 或返回异常。"
      case .mountFailed: return "挂载安装镜像失败。"
      case .appNotFoundInDMG: return "安装镜像中未找到 .app。"
      case .copyFailed: return "复制新版本失败。"
      }
    }
  }

  // MARK: - Check

  /// Asset name uploaded with every GitHub release (see script/make_dmg.sh).
  static let assetName = "Subtle.dmg"

  /// Returns the latest release if it is newer than the running build, else nil.
  ///
  /// Resolves the latest tag via github.com's `releases/latest` redirect instead
  /// of api.github.com, so it is NOT subject to the unauthenticated REST rate
  /// limit (60 req/hour/IP) that several friends behind one IP could exhaust.
  static func checkForUpdate() async throws -> UpdateInfo? {
    guard !repository.hasPrefix("CHANGE-ME") else { throw UpdaterError.notConfigured }

    var request = URLRequest(url: URL(string: "https://github.com/\(repository)/releases/latest")!)
    request.httpMethod = "HEAD"
    request.setValue("Subtle", forHTTPHeaderField: "User-Agent")

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let finalURL = response.url else { throw UpdaterError.badResponse }

    // With a release the URL ends …/releases/tag/vX.Y.Z. With none it redirects
    // to …/releases (no "tag" component) — treat that as "no update", not error.
    let parts = finalURL.pathComponents
    guard let tagIndex = parts.firstIndex(of: "tag"), tagIndex + 1 < parts.count else {
      return nil
    }
    let tag = parts[tagIndex + 1]
    guard isVersion(normalize(tag), newerThan: currentVersion) else { return nil }

    let downloadURL = URL(string:
      "https://github.com/\(repository)/releases/download/\(tag)/\(assetName)")!
    return UpdateInfo(
      version: normalize(tag),
      tag: tag,
      releaseNotes: "",
      downloadURL: downloadURL,
      assetSize: 0
    )
  }

  static func normalize(_ raw: String) -> String {
    var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if v.first == "v" || v.first == "V" { v.removeFirst() }
    return v
  }

  /// Numeric, component-wise semantic-version comparison ("0.10.0" > "0.9.0").
  static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
    let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
    let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(a.count, b.count) {
      let x = i < a.count ? a[i] : 0
      let y = i < b.count ? b[i] : 0
      if x != y { return x > y }
    }
    return false
  }

  // MARK: - Download

  /// Downloads the release DMG to a temp file, reporting fractional progress.
  static func download(
    _ info: UpdateInfo,
    progress: @escaping @Sendable (Double) -> Void
  ) async throws -> URL {
    let dest = FileManager.default.temporaryDirectory
      .appendingPathComponent("Subtle-\(info.version).dmg")
    return try await DMGDownloader(destination: dest, progress: progress)
      .run(from: info.downloadURL)
  }

  // MARK: - Install (swap bundle in place + relaunch)

  @MainActor
  static func installAndRelaunch(dmgPath: URL) async throws {
    let fm = FileManager.default
    let mountPoint = fm.temporaryDirectory.appendingPathComponent("LTMount-\(UUID().uuidString)")

    let attach = try await run("/usr/bin/hdiutil",
      ["attach", dmgPath.path, "-nobrowse", "-noverify", "-noautoopen", "-mountpoint", mountPoint.path])
    guard attach == 0 else { throw UpdaterError.mountFailed }
    defer { try? fm.removeItem(at: mountPoint) }

    let contents = (try? fm.contentsOfDirectory(at: mountPoint, includingPropertiesForKeys: nil)) ?? []
    guard let mountedApp = contents.first(where: { $0.pathExtension == "app" }) else {
      _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
      throw UpdaterError.appNotFoundInDMG
    }

    // Stage a copy outside the image so we can detach before the swap.
    let staged = fm.temporaryDirectory.appendingPathComponent("Subtle-new-\(UUID().uuidString).app")
    try? fm.removeItem(at: staged)
    let dittoStatus = try await run("/usr/bin/ditto", [mountedApp.path, staged.path])
    _ = try? await run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
    guard dittoStatus == 0 else { throw UpdaterError.copyFailed }

    // Write the swap-and-relaunch helper and launch it detached. It waits for
    // this process to exit, replaces the bundle, then reopens the new app.
    let helper = fm.temporaryDirectory.appendingPathComponent("lt-update-\(UUID().uuidString).sh")
    try helperScript.write(to: helper, atomically: true, encoding: .utf8)
    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

    let target = Bundle.main.bundleURL.resolvingSymlinksInPath().path
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/bash")
    task.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier), target, staged.path]
    try task.run()

    NSApp.terminate(nil)
  }

  /// Runs a process to completion without blocking the calling thread.
  @discardableResult
  private static func run(_ launchPath: String, _ args: [String]) async throws -> Int32 {
    try await withCheckedThrowingContinuation { continuation in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: launchPath)
      process.arguments = args
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
      do { try process.run() } catch { continuation.resume(throwing: error) }
    }
  }

  /// $1 = pid to wait on, $2 = install target, $3 = staged new bundle.
  /// Escalates to an admin prompt only if the plain replace is denied.
  private static let helperScript = """
  #!/bin/bash
  PID="$1"
  TARGET="$2"
  STAGED="$3"
  while kill -0 "$PID" 2>/dev/null; do sleep 0.3; done
  sleep 0.5
  if rm -rf "$TARGET" 2>/dev/null && /usr/bin/ditto "$STAGED" "$TARGET" 2>/dev/null; then
    :
  else
    /usr/bin/osascript -e "do shell script \\"rm -rf '$TARGET' && /usr/bin/ditto '$STAGED' '$TARGET'\\" with administrator privileges"
  fi
  rm -rf "$STAGED"
  /usr/bin/open "$TARGET"
  """
}

/// Bridges `URLSessionDownloadTask` progress callbacks into async/await.
/// The delegate queue is serial, so the stored continuation is touched from a
/// single thread; `@unchecked Sendable` documents that invariant.
private final class DMGDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let destination: URL
  private let progress: @Sendable (Double) -> Void
  private var continuation: CheckedContinuation<URL, Error>?

  init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
    self.destination = destination
    self.progress = progress
  }

  func run(from url: URL) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
      session.downloadTask(with: url).resume()
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
    guard totalBytesExpectedToWrite > 0 else { return }
    progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didFinishDownloadingTo location: URL) {
    // Must move synchronously: `location` is deleted once this returns.
    do {
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: location, to: destination)
      progress(1.0)
      continuation?.resume(returning: destination)
    } catch {
      continuation?.resume(throwing: error)
    }
    continuation = nil
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { continuation?.resume(throwing: error); continuation = nil }
    session.finishTasksAndInvalidate()
  }
}
