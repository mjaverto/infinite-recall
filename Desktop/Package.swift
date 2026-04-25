// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Omi Computer",
  platforms: [
    .macOS("14.0")
  ],
  dependencies: [
    // Infinite Recall fork: Firebase/Sentry/Sparkle/Heap removed (local-first, no telemetry).
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    // On-device Whisper transcription (Apache 2.0). Repo redirects to argmax-oss-swift.
    .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
  ],
  targets: [
    .target(
      name: "ObjCExceptionCatcher",
      path: "ObjCExceptionCatcher",
      publicHeadersPath: "include"
    ),
    .systemLibrary(
      name: "CWebP",
      path: "CWebP",
      pkgConfig: "libwebp",
      providers: [
        .brew(["webp"])
      ]
    ),
    .executableTarget(
      name: "Omi Computer",
      dependencies: [
        "ObjCExceptionCatcher",
        "CWebP",
        // Infinite Recall fork: Firebase/Sentry/Sparkle/Heap removed (local-first).
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        .product(name: "WhisperKit", package: "WhisperKit"),
        .product(name: "SpeakerKit", package: "WhisperKit"),
      ],
      path: "Sources",
      resources: [
        .process("Resources"),
      ]
    ),
    .testTarget(
      name: "Omi ComputerTests",
      dependencies: [
        .target(name: "Omi Computer")
      ],
      path: "Tests"
    ),
  ]
)
