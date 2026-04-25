// Infinite Recall fork: local LLM via mlx-lm.server. No cloud calls.
//
// AIProviderRegistry — abstracts over multiple LLM providers. v1 ships only
// the local MLX provider as a working client; the others are wired in as
// stubs so adding them later is a one-switch-case change.

import Foundation
import Security
import SwiftUI

// MARK: - LLMProvider
//
// Note: named `LLMProvider` (not `AIProvider`) to avoid a collision with the
// existing `struct AIProvider` in Providers/AIProvider.swift, which models the
// chat-bridge picker UI. The two abstractions will likely converge in a later
// sprint, but for now they're orthogonal.

enum LLMProvider: String, CaseIterable, Codable, Sendable {
  case localMLX = "local_mlx"
  case anthropic = "anthropic"
  case openai = "openai"
  /// Shell out to a locally-installed CLI (`claude`, `codex`). Stub for now.
  case localCLI = "local_cli"

  var displayName: String {
    switch self {
    case .localMLX: return "Local MLX (Qwen 32B)"
    case .anthropic: return "Anthropic"
    case .openai: return "OpenAI"
    case .localCLI: return "Local CLI"
    }
  }

  /// Whether this provider needs an API key stored in the Keychain.
  var requiresAPIKey: Bool {
    switch self {
    case .localMLX, .localCLI: return false
    case .anthropic, .openai: return true
    }
  }
}

// MARK: - Registry errors

enum AIProviderError: LocalizedError {
  case notYetImplemented(LLMProvider)
  case missingAPIKey(LLMProvider)

  var errorDescription: String? {
    switch self {
    case .notYetImplemented(let p):
      return "Provider not yet implemented: \(p.displayName)"
    case .missingAPIKey(let p):
      return "Missing API key for provider: \(p.displayName)"
    }
  }
}

// MARK: - AIProviderRegistry

/// Singleton registry. UI binds to `current`; callers ask `makeClient()` for an
/// `LLMClient` to actually run a request against.
@MainActor
final class AIProviderRegistry: ObservableObject {

  static let shared = AIProviderRegistry()

  /// UserDefaults key for the persisted provider selection.
  private static let providerStorageKey = "InfiniteRecall.AIProvider.selected"

  /// Currently selected provider. Persisted to UserDefaults.
  @Published var current: LLMProvider {
    didSet {
      UserDefaults.standard.set(current.rawValue, forKey: Self.providerStorageKey)
    }
  }

  private init() {
    if let raw = UserDefaults.standard.string(forKey: Self.providerStorageKey),
      let p = LLMProvider(rawValue: raw)
    {
      self.current = p
    } else {
      self.current = .localMLX
    }
  }

  // MARK: Provider switching

  func setProvider(_ p: LLMProvider) {
    current = p
  }

  // MARK: Keychain-backed API keys

  /// Service identifier used for all Keychain reads/writes.
  private static let keychainService = "com.infiniterecall.aiproviders"

  func setAPIKey(_ key: String, for provider: LLMProvider) {
    Self.keychainSet(account: provider.rawValue, value: key)
  }

  func apiKey(for provider: LLMProvider) -> String? {
    Self.keychainGet(account: provider.rawValue)
  }

  func clearAPIKey(for provider: LLMProvider) {
    Self.keychainDelete(account: provider.rawValue)
  }

  // MARK: Client factory

  /// Returns a working `LLMClient` for the current provider.
  /// Throws `AIProviderError.notYetImplemented` for any provider other than
  /// `.localMLX` until those are wired up in a future sprint.
  func makeClient() throws -> any LLMClient {
    try makeClient(for: current)
  }

  /// Returns a client for an explicit provider (lets callers preview a provider
  /// without flipping the global `current`).
  func makeClient(for provider: LLMProvider) throws -> any LLMClient {
    switch provider {
    case .localMLX:
      return LocalLLMClient.shared
    case .anthropic, .openai, .localCLI:
      throw AIProviderError.notYetImplemented(provider)
    }
  }

  // MARK: - Keychain primitives

  /// Store a value (UTF-8) under `account` in the kSecClassGenericPassword
  /// keychain bucket scoped to `keychainService`. Overwrites any existing item.
  @discardableResult
  private static func keychainSet(account: String, value: String) -> Bool {
    guard let data = value.data(using: .utf8) else { return false }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
    ]

    // Delete existing item, ignore errSecItemNotFound.
    SecItemDelete(query as CFDictionary)

    var attrs = query
    attrs[kSecValueData as String] = data
    attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

    let status = SecItemAdd(attrs as CFDictionary, nil)
    return status == errSecSuccess
  }

  private static func keychainGet(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
      let data = item as? Data,
      let str = String(data: data, encoding: .utf8)
    else {
      return nil
    }
    return str
  }

  @discardableResult
  private static func keychainDelete(account: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}
