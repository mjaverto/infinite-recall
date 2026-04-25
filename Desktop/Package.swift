// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "Omi Computer",
  platforms: [
    .macOS("14.0")
  ],
  dependencies: [
    // Infinite Recall fork: Mixpanel/PostHog/Heap SPM deps removed (telemetry stripped).
    // Firebase, Sentry, and Sparkle remain — they're still imported across AuthService,
    // Logger/ResourceMonitor, and UpdaterViewModel respectively. Removing them is a
    // larger refactor (gut AuthService, no-op SentrySDK call sites, stub UpdaterViewModel).
    .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa.git", exact: "8.58.0"),
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    .package(
      url: "https://github.com/microsoft/onnxruntime-swift-package-manager.git", from: "1.20.0"),
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
        .product(name: "FirebaseCore", package: "firebase-ios-sdk"),
        .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
        // Infinite Recall fork: Mixpanel/PostHog/HeapSwiftCore products removed.
        .product(name: "Sentry", package: "sentry-cocoa"),
        .product(name: "GRDB", package: "GRDB.swift"),
        .product(name: "Sparkle", package: "Sparkle"),
        .product(name: "MarkdownUI", package: "swift-markdown-ui"),
        .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
        .product(name: "WhisperKit", package: "WhisperKit"),
        .product(name: "SpeakerKit", package: "WhisperKit"),
      ],
      path: "Sources",
      resources: [
        .process("GoogleService-Info.plist"),
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
