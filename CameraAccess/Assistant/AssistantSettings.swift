//
// AssistantSettings.swift
// Nave Glasses — keys and preferences for the Claude assistant.
// API keys live in the Keychain (falls back to UserDefaults only if the
// Keychain is unavailable under free sideload signing). Nothing is in the repo.
//

import Foundation
import Security

enum SecretStore {
  private static let service = "com.navepro12.glassesapp.secrets"

  static func get(_ key: String) -> String {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
      let data = item as? Data, let value = String(data: data, encoding: .utf8)
    {
      return value
    }
    return UserDefaults.standard.string(forKey: "fallback." + key) ?? ""
  }

  static func set(_ key: String, _ value: String) {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: key,
    ]
    SecItemDelete(base as CFDictionary)
    guard !value.isEmpty else {
      UserDefaults.standard.removeObject(forKey: "fallback." + key)
      return
    }
    var add = base
    add[kSecValueData as String] = Data(value.utf8)
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
    if SecItemAdd(add as CFDictionary, nil) == errSecSuccess {
      UserDefaults.standard.removeObject(forKey: "fallback." + key)
    } else {
      UserDefaults.standard.set(value, forKey: "fallback." + key)
    }
  }
}

enum ListenLanguage: String, CaseIterable, Identifiable {
  case hebrew = "he-IL"
  case english = "en-US"
  var id: String { rawValue }
  var label: String { self == .hebrew ? "עברית" : "English" }
}

enum ClaudeModel: String, CaseIterable, Identifiable {
  case sonnet = "claude-sonnet-5-5"
  case haiku = "claude-haiku-5-5"
  var id: String { rawValue }
  var label: String { self == .sonnet ? "Sonnet (חכם)" : "Haiku (מהיר)" }
}

enum VoiceProvider: String, CaseIterable, Identifiable {
  case apple, azure, eleven, gemini
  var id: String { rawValue }
  var label: String {
    switch self {
    case .apple: return "אייפון (חינם)"
    case .azure: return "Azure"
    case .eleven: return "ElevenLabs"
    case .gemini: return "Gemini"
    }
  }
}

enum HebrewVoice: String, CaseIterable, Identifiable {
  case hila = "he-IL-HilaNeural"
  case avri = "he-IL-AvriNeural"
  var id: String { rawValue }
  var label: String { self == .hila ? "הילה (אישה)" : "אברי (גבר)" }
}

@MainActor
final class AssistantSettings {
  static let shared = AssistantSettings()
  private let defaults = UserDefaults.standard

  var anthropicKey: String {
    get { SecretStore.get("anthropic") }
    set { SecretStore.set("anthropic", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }
  var azureKey: String {
    get { SecretStore.get("azure") }
    set { SecretStore.set("azure", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }
  var elevenKey: String {
    get { SecretStore.get("eleven") }
    set { SecretStore.set("eleven", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }
  var elevenVoiceID: String {
    get { defaults.string(forKey: "elevenVoiceID") ?? "21m00Tcm4TlvDq8ikWAM" }
    set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "elevenVoiceID") }
  }
  var geminiKey: String {
    get { SecretStore.get("gemini") }
    set { SecretStore.set("gemini", newValue.trimmingCharacters(in: .whitespacesAndNewlines)) }
  }
  var geminiVoice: String {
    get { defaults.string(forKey: "geminiVoice") ?? "Kore" }
    set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "geminiVoice") }
  }
  var voiceProvider: VoiceProvider {
    get {
      if let raw = defaults.string(forKey: "voiceProvider"), let v = VoiceProvider(rawValue: raw) { return v }
      return azureKey.isEmpty ? .apple : .azure
    }
    set { defaults.set(newValue.rawValue, forKey: "voiceProvider") }
  }
  var azureRegion: String {
    get { defaults.string(forKey: "azureRegion") ?? "westeurope" }
    set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), forKey: "azureRegion") }
  }
  var listenLanguage: ListenLanguage {
    get { ListenLanguage(rawValue: defaults.string(forKey: "listenLanguage") ?? "") ?? .hebrew }
    set { defaults.set(newValue.rawValue, forKey: "listenLanguage") }
  }
  var model: ClaudeModel {
    get { ClaudeModel(rawValue: defaults.string(forKey: "model") ?? "") ?? .sonnet }
    set { defaults.set(newValue.rawValue, forKey: "model") }
  }
  var hebrewVoice: HebrewVoice {
    get { HebrewVoice(rawValue: defaults.string(forKey: "hebrewVoice") ?? "") ?? .hila }
    set { defaults.set(newValue.rawValue, forKey: "hebrewVoice") }
  }
  /// Send the current glasses frame with each question.
  var useCamera: Bool {
    get { defaults.object(forKey: "useCamera") as? Bool ?? true }
    set { defaults.set(newValue, forKey: "useCamera") }
  }
}
