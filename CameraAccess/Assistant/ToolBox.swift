//
// ToolBox.swift
// Runs the actions Claude asks for: calls, WhatsApp, logging to the PC,
// live chat on/off, and a sharp full-resolution photo.
//

import Contacts
import CoreLocation
import Foundation
import MapKit
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

    // MARK: Daily life

    case "add_reminder":
      let title = input["title"] as? String ?? ""
      guard !title.isEmpty else { return "A title is required." }
      return await CalendarAgent.shared.addReminder(
        title: title, dueAt: input["due_at"] as? String, inMinutes: Self.int(input["in_minutes"]),
        notes: input["notes"] as? String)

    case "list_reminders":
      return await CalendarAgent.shared.openReminders()

    case "get_agenda":
      return await CalendarAgent.shared.agenda(dayOffset: Self.int(input["day_offset"]) ?? 0)

    case "add_event":
      let title = input["title"] as? String ?? ""
      let start = input["start_at"] as? String ?? ""
      guard !title.isEmpty, !start.isEmpty else { return "title and start_at are required." }
      return await CalendarAgent.shared.addEvent(
        title: title, startAt: start, minutes: Self.int(input["minutes"]) ?? 60, location: input["location"] as? String)

    case "set_timer":
      let seconds = Self.int(input["seconds"]) ?? 0
      return await TimerAgent.shared.set(seconds: seconds, label: input["label"] as? String ?? "")

    case "timers":
      if (input["action"] as? String) == "cancel" { return TimerAgent.shared.cancelAll() }
      return TimerAgent.shared.status()

    case "remember_this":
      let text = input["text"] as? String ?? ""
      guard !text.isEmpty else { return "Say what to remember." }
      let withPhoto = (input["with_photo"] as? Bool) ?? true
      let image = withPhoto ? frameProvider() : nil
      let fix = await LocationContext.shared.currentFix(maxWait: 3)
      let item = VisualMemoryStore.shared.remember(
        text: text, image: image, fix: fix, place: LocationContext.shared.placeName)
      var out = "Remembered: \(VisualMemoryStore.describe(item))."
      if image == nil, withPhoto { out += " (No camera frame was available, saved without a photo.)" }
      return out

    case "recall_memory":
      let query = input["query"] as? String ?? ""
      let hits = VisualMemoryStore.shared.recall(query: query, limit: 5)
      guard !hits.isEmpty else {
        if VisualMemoryStore.shared.items.isEmpty { return "No memories saved yet." }
        let newest = VisualMemoryStore.shared.recall(query: "", limit: 5).map(VisualMemoryStore.describe)
        return "Nothing matching '\(query)'. Newest memories:\n" + newest.joined(separator: "\n")
      }
      var blocks: [[String: Any]] = [["type": "text", "text": "Matching memories (newest first):\n" + hits.map(VisualMemoryStore.describe).joined(separator: "\n")]]
      if let image = VisualMemoryStore.shared.image(for: hits[0]), let jpeg = ClaudeClient.jpeg(image, maxSide: 800) {
        blocks.append(["type": "text", "text": "Photo of the first match:"])
        blocks.append(ClaudeClient.imageBlock(jpeg))
      }
      return blocks

    case "forget_memory":
      let prefix = input["id"] as? String ?? ""
      guard let item = VisualMemoryStore.shared.items.first(where: { $0.id.hasPrefix(prefix) && !prefix.isEmpty }) else {
        return "No memory with id \(prefix)."
      }
      VisualMemoryStore.shared.forget(id: item.id)
      return "Forgot: \(item.text)."

    case "navigate":
      if let id = input["memory_id"] as? String, !id.isEmpty,
        let item = VisualMemoryStore.shared.items.first(where: { $0.id.hasPrefix(id) }),
        let lat = item.latitude, let lon = item.longitude
      {
        return await Navigator.navigate(latitude: lat, longitude: lon, label: item.text)
      }
      return await Navigator.navigate(to: input["destination"] as? String ?? "")

    case "distance_to":
      return await Self.distance(to: input["place"] as? String ?? "")

    case "where_am_i":
      LocationContext.shared.start()
      if let fix = await LocationContext.shared.currentFix(maxWait: 4) {
        let place = LocationContext.shared.placeName
        return "Location: \(place.isEmpty ? "unknown place" : place) at \(String(format: "%.5f, %.5f", fix.latitude, fix.longitude)). Time now: \(IsraelClock.nowLine)."
      }
      return LocationContext.shared.authorized
        ? "No GPS fix yet. Time now: \(IsraelClock.nowLine)."
        : "Location is off — Nave can allow it in iPhone Settings → Nave Glasses → Location. Time now: \(IsraelClock.nowLine)."

    default:
      return "Unknown tool \(name)."
    }
  }

  /// Local search near the current fix + driving ETA.
  static func distance(to place: String) async -> String {
    guard !place.trimmingCharacters(in: .whitespaces).isEmpty else { return "No place given." }
    LocationContext.shared.start()
    guard let fix = await LocationContext.shared.currentFix(maxWait: 4) else {
      return "No location fix — location may be off (iPhone Settings → Nave Glasses → Location)."
    }
    let here = CLLocationCoordinate2D(latitude: fix.latitude, longitude: fix.longitude)
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = place
    request.region = MKCoordinateRegion(center: here, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
    guard let response = try? await MKLocalSearch(request: request).start(),
      let item = response.mapItems.first
    else { return "Couldn't find \(place) on the map." }
    let target = item.placemark.coordinate
    let meters = CLLocation(latitude: here.latitude, longitude: here.longitude)
      .distance(from: CLLocation(latitude: target.latitude, longitude: target.longitude))
    let address = [item.placemark.thoroughfare, item.placemark.subThoroughfare, item.placemark.locality]
      .compactMap { $0 }.joined(separator: " ")
    var line = "\(item.name ?? place) — \(address). Straight-line distance \(String(format: "%.1f", meters / 1000)) km."
    let directions = MKDirections.Request()
    directions.source = MKMapItem(placemark: MKPlacemark(coordinate: here))
    directions.destination = item
    directions.transportType = .automobile
    if let eta = try? await MKDirections(request: directions).calculateETA() {
      line += " Driving about \(Int((eta.expectedTravelTime / 60).rounded())) min (\(String(format: "%.1f", eta.distance / 1000)) km by road)."
    }
    return line
  }

  private static func int(_ value: Any?) -> Int? {
    if let i = value as? Int { return i }
    if let d = value as? Double { return Int(d) }
    if let s = value as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
    return nil
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
