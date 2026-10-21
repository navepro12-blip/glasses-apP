//
// VisualMemory.swift
// "Remember this": a glasses photo + a short note + where/when, kept on the
// phone (Application Support/Memories). Answers "where did I park / put…"
// later. Small by design: ~100 KB JPEGs, newest 200 kept.
//

import CoreLocation
import Foundation
import UIKit

struct MemoryItem: Codable, Identifiable, Sendable {
  let id: String
  let date: Date
  var text: String
  var latitude: Double?
  var longitude: Double?
  var place: String
  var imageFile: String?
}

@MainActor
final class VisualMemoryStore {
  static let shared = VisualMemoryStore()

  private(set) var items: [MemoryItem] = []
  private let folder: URL
  private let indexURL: URL

  init() {
    let base = (try? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
      ?? FileManager.default.temporaryDirectory
    folder = base.appendingPathComponent("Memories", isDirectory: true)
    indexURL = folder.appendingPathComponent("memories.json")
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    load()
  }

  private func load() {
    guard let data = try? Data(contentsOf: indexURL) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    items = (try? decoder.decode([MemoryItem].self, from: data)) ?? []
  }

  private func save() {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(items) {
      try? data.write(to: indexURL, options: .atomic)
    }
  }

  /// Saves a memory; returns the stored item.
  func remember(text: String, image: UIImage?, fix: LocationContext.Fix?, place: String) -> MemoryItem {
    let id = UUID().uuidString
    var file: String?
    if let image, let jpeg = ClaudeClient.jpeg(image, maxSide: 900) {
      let name = id + ".jpg"
      if (try? jpeg.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil { file = name }
    }
    let item = MemoryItem(
      id: id, date: Date(), text: text, latitude: fix?.latitude, longitude: fix?.longitude,
      place: place, imageFile: file)
    items.insert(item, at: 0)
    while items.count > 200 {
      let old = items.removeLast()
      if let f = old.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
    }
    save()
    return item
  }

  func forget(id: String) {
    guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
    let item = items.remove(at: idx)
    if let f = item.imageFile { try? FileManager.default.removeItem(at: folder.appendingPathComponent(f)) }
    save()
  }

  func image(for item: MemoryItem) -> UIImage? {
    guard let f = item.imageFile else { return nil }
    return UIImage(contentsOfFile: folder.appendingPathComponent(f).path)
  }

  /// Keyword search (Hebrew-friendly: tokens match on shared stems of 3+ letters).
  /// Empty query → newest items.
  func recall(query: String, limit: Int = 5) -> [MemoryItem] {
    let q = Self.tokens(query)
    guard !q.isEmpty else { return Array(items.prefix(limit)) }
    let scored: [(MemoryItem, Int)] = items.map { item in
      let t = Self.tokens(item.text + " " + item.place)
      var score = 0
      for a in q {
        for b in t where Self.similar(a, b) { score += a == b ? 3 : 1 }
      }
      return (item, score)
    }
    let hits = scored.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map { $0.0 }
    return Array(hits.prefix(limit))
  }

  /// One line per item, for Claude.
  static func describe(_ item: MemoryItem) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "he_IL")
    f.dateFormat = "EEEE d.M HH:mm"
    var line = "[\(item.id.prefix(8))] \(f.string(from: item.date)): \(item.text)"
    if !item.place.isEmpty { line += " — \(item.place)" }
    if let lat = item.latitude, let lon = item.longitude {
      line += String(format: " (%.4f, %.4f)", lat, lon)
    }
    if item.imageFile != nil { line += " [photo]" }
    return line
  }

  private static func tokens(_ s: String) -> [String] {
    let stop: Set<String> = ["את", "של", "על", "איפה", "מה", "the", "where", "did", "i", "my", "a", "to", "is", "it"]
    return WakeWord.normalize(s)
      .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
      .map { String($0) }
      .map { t in
        // strip common Hebrew prefixes (ה, ב, ל, ו, מ, ש, כ) from longer words
        var w = t
        if w.count > 3, let first = w.first, "הבלומשכ".contains(first) { w.removeFirst() }
        return w
      }
      .filter { $0.count >= 2 && !stop.contains($0) }
  }

  private static func similar(_ a: String, _ b: String) -> Bool {
    if a == b { return true }
    guard a.count >= 3, b.count >= 3 else { return false }
    return a.hasPrefix(b) || b.hasPrefix(a) || (a.count >= 4 && b.contains(a)) || (b.count >= 4 && a.contains(b))
  }
}
