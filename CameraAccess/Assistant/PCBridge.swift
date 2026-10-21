//
// PCBridge.swift
// Talks to the server on Nave's PC (pc-voice-server): uploads recordings,
// logs inventory/ideas, TikTok live chat, and the OBS camera feed.
//

import Foundation
import UIKit

enum PCBridge {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  @MainActor static var baseURL: URL? {
    var base = AssistantSettings.shared.pcURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !base.isEmpty else { return nil }
    if !base.hasPrefix("http") { base = "http://" + base }
    while base.hasSuffix("/") { base.removeLast() }
    return URL(string: base)
  }

  @MainActor static func requireBase() throws -> URL {
    guard let url = baseURL else { throw Failure(message: "חסרה כתובת המחשב בהגדרות") }
    return url
  }

  /// Uploads a finished recording to the PC media folder.
  @MainActor static func upload(fileAt url: URL) async throws {
    let base = try requireBase()
    var request = URLRequest(url: base.appendingPathComponent("upload"))
    request.httpMethod = "POST"
    request.timeoutInterval = 300
    request.setValue(url.lastPathComponent, forHTTPHeaderField: "X-Filename")
    let (_, response) = try await URLSession.shared.upload(for: request, fromFile: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(message: "ההעלאה למחשב נכשלה") }
  }

  /// kind: "inventory" | "idea" | "note"
  @MainActor static func log(kind: String, text: String, jpeg: Data?) async throws {
    let base = try requireBase()
    var body: [String: Any] = ["kind": kind, "text": text]
    if let jpeg { body["image_b64"] = jpeg.base64EncodedString() }
    _ = try await postJSON(base.appendingPathComponent("log"), body)
  }

  @MainActor static func tiktokStart(username: String) async throws {
    let base = try requireBase()
    _ = try await postJSON(base.appendingPathComponent("tiktok/start"), ["username": username])
  }

  @MainActor static func tiktokStop() async {
    guard let base = baseURL else { return }
    _ = try? await postJSON(base.appendingPathComponent("tiktok/stop"), [:])
  }

  struct ChatEvent: Sendable {
    let id: Int
    let type: String
    let user: String
    let text: String
  }

  @MainActor static func tiktokEvents(after: Int) async throws -> (status: String, events: [ChatEvent]) {
    let base = try requireBase()
    var comps = URLComponents(url: base.appendingPathComponent("tiktok/events"), resolvingAgainstBaseURL: false)!
    comps.queryItems = [URLQueryItem(name: "after", value: String(after))]
    var request = URLRequest(url: comps.url!)
    request.timeoutInterval = 6
    let (data, _) = try await URLSession.shared.data(for: request)
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ("?", []) }
    let status = json["status"] as? String ?? "?"
    let events = (json["events"] as? [[String: Any]] ?? []).compactMap { e -> ChatEvent? in
      guard let id = e["id"] as? Int else { return nil }
      return ChatEvent(id: id, type: e["type"] as? String ?? "", user: e["user"] as? String ?? "", text: e["text"] as? String ?? "")
    }
    return (status, events)
  }

  private static func postJSON(_ url: URL, _ body: [String: Any]) async throws -> Data {
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 15
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw Failure(message: "המחשב החזיר שגיאה: \(String(data: data, encoding: .utf8)?.prefix(120) ?? "")")
      }
      return data
    } catch let e as Failure {
      throw e
    } catch {
      throw Failure(message: "אין חיבור למחשב — השרת דלוק? אותה רשת?")
    }
  }
}

/// Reads the TikTok LIVE chat aloud into the glasses.
@Observable
@MainActor
final class LiveChatReader {
  static let shared = LiveChatReader()

  private(set) var isOn = false
  private(set) var status = ""
  private(set) var lastLine = ""
  @ObservationIgnored private var lastID = 0
  @ObservationIgnored private var pollTask: Task<Void, Never>?

  func start() async {
    let user = AssistantSettings.shared.tiktokUsername
    guard !user.isEmpty else {
      status = "חסר שם משתמש טיקטוק בהגדרות"
      return
    }
    do {
      try await PCBridge.tiktokStart(username: user)
      isOn = true
      status = "מתחבר ללייב…"
      lastID = 0
      // Skip the backlog: only read what arrives from now on.
      if let first = try? await PCBridge.tiktokEvents(after: 0) { lastID = first.events.last?.id ?? 0 }
      pollTask?.cancel()
      pollTask = Task { [weak self] in await self?.poll() }
    } catch {
      status = error.localizedDescription
    }
  }

  func stop() {
    pollTask?.cancel()
    pollTask = nil
    isOn = false
    status = ""
    Task { await PCBridge.tiktokStop() }
  }

  private func poll() async {
    while !Task.isCancelled, isOn {
      do {
        let result = try await PCBridge.tiktokEvents(after: lastID)
        status = switch result.status {
        case "live": "🔴 מחובר לצ'אט"
        case "connecting": "מתחבר ללייב…"
        case "ended": "הלייב הסתיים"
        default: result.status
        }
        speak(result.events)
      } catch {
        status = "אין חיבור למחשב"
      }
      try? await Task.sleep(for: .milliseconds(1200))
    }
  }

  private func speak(_ events: [PCBridge.ChatEvent]) {
    guard let last = events.last else { return }
    lastID = last.id
    // Keep up with a busy chat: read at most 4 per round and summarise the rest.
    let speakable = events.filter { $0.type != "comment" || !$0.text.isEmpty }
    let budget = max(0, 4 - SpeechOutput.shared.queuedCount)
    for e in speakable.prefix(budget) {
      let line: String
      switch e.type {
      case "follow": line = "\(e.user) התחיל לעקוב"
      case "gift": line = "\(e.user) שלח \(e.text)"
      default: line = "\(e.user): \(e.text)"
      }
      lastLine = line
      SpeechOutput.shared.enqueue(line)
    }
    let skipped = speakable.count - min(speakable.count, budget)
    if skipped > 2 { SpeechOutput.shared.enqueue("ועוד \(skipped) תגובות") }
  }
}

/// Sends the glasses camera to OBS on the PC (Browser Source: http://localhost:8790/cam).
@MainActor
final class ObsStreamer {
  static let shared = ObsStreamer()

  private var socket: URLSessionWebSocketTask?
  private var sending = false
  private var lastSent = Date.distantPast
  private var connectedTo: URL?

  var isEnabled: Bool { AssistantSettings.shared.obsEnabled }

  func offer(_ image: UIImage) {
    guard isEnabled, !sending, Date().timeIntervalSince(lastSent) > 1.0 / 15.0 else { return }
    guard let base = PCBridge.baseURL else { return }
    var comps = URLComponents(url: base.appendingPathComponent("cam/push"), resolvingAgainstBaseURL: false)!
    comps.scheme = comps.scheme == "https" ? "wss" : "ws"
    guard let wsURL = comps.url else { return }
    if socket == nil || connectedTo != wsURL {
      socket?.cancel()
      let task = URLSession.shared.webSocketTask(with: wsURL)
      task.resume()
      socket = task
      connectedTo = wsURL
    }
    guard let jpeg = image.jpegData(compressionQuality: 0.7), let socket else { return }
    sending = true
    lastSent = Date()
    socket.send(.data(jpeg)) { [weak self] error in
      Task { @MainActor in
        guard let self else { return }
        self.sending = false
        if error != nil {
          self.socket?.cancel()
          self.socket = nil
        }
      }
    }
  }

  func stop() {
    socket?.cancel()
    socket = nil
  }
}
