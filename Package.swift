// swift-tools-version: 6.0

import Foundation
import PackageDescription

var targets: [Target] = [
  // Tools 6.0 is required for Swift Testing support in `swift test`; the
  // language mode stays v5 so the build semantics match the pre-bump state.
  .executableTarget(
    name: "Subtle",
    path: "Sources/Subtle",
    swiftSettings: [.swiftLanguageMode(.v5)]
  )
]

// Tests/ is not part of the published repository; only declare the test
// target when the directory exists so a fresh clone still builds.
let testsDir = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .appendingPathComponent("Tests/SubtleTests")
if FileManager.default.fileExists(atPath: testsDir.path) {
  // The Command Line Tools toolchain ships Testing.framework but SwiftPM
  // only passes `-I` to it; the explicit `-F`/rpath flags below make
  // `swift test` work without a full Xcode install.
  targets.append(
    .testTarget(
      name: "SubtleTests",
      dependencies: ["Subtle"],
      path: "Tests/SubtleTests",
      swiftSettings: [
        .swiftLanguageMode(.v5),
        .unsafeFlags([
          "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
          // CLT ships an incomplete _Testing_Foundation cross-import overlay;
          // disabling overlays avoids "no such module" without losing tests.
          "-Xfrontend", "-disable-cross-import-overlays",
        ]),
      ],
      linkerSettings: [
        .unsafeFlags([
          "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
          "-Xlinker", "-rpath",
          "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
        ])
      ]
    )
  )
}

let package = Package(
  name: "Subtle",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .executable(name: "Subtle", targets: ["Subtle"])
  ],
  targets: targets
)
