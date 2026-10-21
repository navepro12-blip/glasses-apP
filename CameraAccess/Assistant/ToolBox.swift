//
// ToolBox.swift
// Runs the actions Claude asks for: calls, WhatsApp, logging to the PC,
// live chat on/off, and a sharp full-resolution photo.
//

import Contacts
import Foundation
import UIKit

@MainActor
final class ToolBox {
  var frameProvider: @MainActor () -> UIImage? = { nil }
  var stillProvider: @MainActor () async -> UIImage? = { nil }

  /// Returns tool_result content (a string or content blocks).
  func run(name: String, input: [String: Any]) async -> Any {
    switch name {
    case "look_closer":
      guard let image = await stillProvider() ?? frameProvider(), let jpeg = ClaudeClient.jpeg(image, maxSide: 1600)
      else { return "No camera image available — the preview isn't running." }
      return [ClaudeClient.imageBlock(jpeg), ["type": "text", "text": "Full-resolution photo from the glasses."]]

    case "call_contact":
      let names = input["names"] as? [String] ?? []
      switch await Self.findPhone(names: names) {
      case .one(let person, let phone):
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard let url = URL(string: "tel://\(digits)") else { return "Invalid number for \(person)." }
        await UIApplication.shared.open(url)
        return "Calling \(person) (\(phone)). Nave needs to tap Call on the phone to confirm."
      case .many(let options):
        return "Several matches: \(options.joined(separator: ", ")). Ask Nave which one."
      case .none(let reason):
        return reason
      }

    case "send_whatsapp":
      let names = input["names"] as? [String] ?? []
      let message = input["message"] as? String ?? ""
      switch await Self.findPhone(names: names) {
      case .one(let person, let phone):
        let intl = Self.internationalDigits(phone)
        var comps = URLComponents(string: "https://wa.me/\(intl)")!
        comps.queryItems = [URLQueryItem(name: "text", value: message)]
        guard let url = comps.url else { return "Couldn't build the WhatsApp link." }
        await UIApplication.shared.open(url)
        return "WhatsApp opened to \(person) with the message ready; Nave taps send."
      case .many(let options):
        return "Several matches: \(options.joined(separator: ", ")). Ask Nave which one."
      case .none(let reason):
        return reason
      }

    case "log_inventory":
      let text = input["description"] as? String ?? ""
      let jpeg = frameProvider().flatMap { ClaudeClient.jpeg($0, maxSide: 1600) }
      do {
        try await PCBridge.log(kind: "inventory", text: text, jpeg: jpeg)
        return "Saved to the inventory sheet on the PC."
      } catch {
        return "Failed: \(error.localizedDescription)"
      }

    case "save_note":
      let kind = input["kind"] as? String ?? "note"
      let text = input["text"] as? String ?? ""
      do {
        try await PCBridge.log(kind: kind == "idea" ? "idea" : "note", text: text, jpeg: nil)
        return "Saved on the PC."
      } catch {
        return "Failed: \(error.localizedDescription)"
      }

    case "live_chat":
      if (input["action"] as? String) == "stop" {
        LiveChatReader.shared.stop()
        return "Live chat reading stopped."
      }
      await LiveChatReader.shared.start()
      return LiveChatReader.shared.isOn
        ? "Live chat reading started for @\(AssistantSettings.shared.tiktokUsername)."
        : "Couldn't start: \(LiveChatReader.shared.status)"

    default:
      return "Unknown tool \(name)."
    }
  }

  // MARK: - Contacts

  enum PhoneMatch {
    case one(String, String)
    case many([String])
    case none(String)
  }

  static func findPhone(names: [String]) async -> PhoneMatch {
    let store = CNContactStore()
    let granted = (try? await store.requestAccess(for: .contacts)) ?? false
    guard granted else { return .none("No access to contacts — allow it in iPhone Settings.") }
    let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
    var found: [String: (String, String)] = [:]
    for name in names where !name.trimmingCharacters(in: .whitespaces).isEmpty {
      let predicate = CNContact.predicateForContacts(matchingName: name)
      let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
      for c in contacts {
        guard let phone = c.phoneNumbers.first?.value.stringValue else { continue }
        let display = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
        found[c.identifier] = (display.isEmpty ? c.nickname : display, phone)
      }
    }
    if found.isEmpty { return .none("No contact found for \(names.joined(separator: " / ")).") }
    if found.count == 1, let only = found.values.first { return .one(only.0, only.1) }
    return .many(found.values.map { "\($0.0) (\($0.1))" })
  }

  /// 050-1234567 → 972501234567 (Israeli default); +44… stays as is.
  static func internationalDigits(_ phone: String) -> String {
    var digits = phone.filter(\.isNumber)
    if phone.trimmingCharacters(in: .whitespaces).hasPrefix("+") { return digits }
    if digits.hasPrefix("00") { digits.removeFirst(2); return digits }
    if digits.hasPrefix("0") { digits.removeFirst(); return "972" + digits }
    return digits
  }
}
