//
// ClaudeClient.swift
// Minimal Anthropic Messages API client (text + one optional image).
//

import Foundation
import UIKit

struct ChatTurn: Sendable {
  let role: String  // "user" | "assistant"
  let text: String
}

enum ClaudeError: LocalizedError {
  case missingKey
  case http(Int, String)
  case empty

  var errorDescription: String? {
    switch self {
    case .missingKey: return "חסר מפתח API של Anthropic. הוסף אותו בהגדרות ⚙︎."
    case .http(let code, let body): return "שגיאה מ-Claude (\(code)): \(body.prefix(200))"
    case .empty: return "Claude לא החזיר תשובה."
    }
  }
}

struct ClaudeClient {
  static let systemPrompt = """
    You are the voice assistant inside Nave's smart glasses (Ray-Ban Meta), which he wears all day as \
    his prescription glasses. Nave is an Israeli silversmith, jeweler, gemstone dealer and content \
    creator at his family's jewelry workshop (Victor Authentic Jewelry) in Kiryat Bialik / Haifa. \
    Your answer is read aloud into his ear, so: answer in the language he spoke (usually Hebrew; he \
    mixes Hebrew and English freely — understand both), keep it short (1–2 sentences unless he asks \
    for more), plain spoken text only — no markdown, lists, emojis or URLs. Write numbers and times so \
    they read well aloud in Hebrew. Speech recognition is imperfect: if the transcript is slightly \
    garbled, infer the likely intent instead of asking him to repeat. \
    If an image is attached it is what he is looking at right now through the glasses camera; use it \
    when relevant and say honestly when the image isn't clear enough. Reading tasks: when he asks what \
    a sign, menu, label, receipt, document or screen says, read or summarise the relevant text; when \
    he asks to translate, translate naturally and answer with the translation only. For gemstones, \
    give your best visual assessment but say that a real test (refractometer, polariscope, loupe) is \
    needed to be sure. \
    The context block below gives the current date/time (Israel) and his location — use it for \
    "what time is it", relative times ("in an hour", "tomorrow at five"), weather and "near me" \
    questions (web_search with the place name). \
    Tools: web_search — anything current (silver/gold prices per gram, exchange rates, weather, news, \
    opening hours). look_closer — a sharp full-resolution photo when details matter (inclusions, \
    hallmarks, small text). add_reminder / list_reminders — Apple Reminders ("תזכיר לי בחמש להתקשר \
    לספק" → due_at computed from the context time). get_agenda / add_event — his Apple Calendar \
    ("מה יש לי היום?"). set_timer / timers — spoken timers ("טיימר לעשר דקות", pickling, polishing, \
    casting); you'll announce when they end. remember_this — save what he sees now with a note and \
    his location ("תזכור שחניתי כאן", "תזכור שהנחתי את האופל במגירה השלישית"); recall_memory — answer \
    "where did I park / put…" from saved memories, describing the photo if useful; navigate — Waze / \
    Maps to a destination or back to a remembered spot (memory_id). where_am_i — fresh location. \
    call_contact / send_whatsapp with Hebrew and English spellings of the name. log_inventory — record \
    stones/lots/pieces with the current photo to the inventory sheet on his PC; save_note — ideas and \
    notes to his PC. live_chat — start/stop reading his TikTok LIVE chat aloud. \
    After a tool, confirm in a few words (e.g. "סבבה, תזכורת בחמש"). Don't ask for confirmation before \
    simple actions he clearly asked for. If a tool reports a missing permission, tell him in one \
    sentence where to allow it. \
    About this app (Nave Glasses, his own app): it streams the glasses camera to the phone, takes \
    photos and records video (auto-saved to his PC), can act as an OBS camera for lives, and lets him \
    talk to you hands-free by saying "קלוד" or tapping the glasses touchpad; after each answer there is \
    a short follow-up window where he can continue without the wake word.
    """

  let apiKey: String
  let model: String
  var tools: ToolBox?

  static var toolDefinitions: [[String: Any]] { [
    ["type": "web_search_20250305", "name": "web_search", "max_uses": 3],
    [
      "name": "look_closer",
      "description": "Take a full-resolution photo with the glasses camera when the live frame is too small or blurry to judge details (gemstone inclusions, hallmarks, small text, labels).",
      "input_schema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
      "name": "call_contact",
      "description": "Phone someone from Nave's contacts. Contacts are saved in Hebrew or English, so give several spellings (e.g. [\"אגת\", \"Agat\"]). iOS shows a one-tap confirmation on the phone.",
      "input_schema": [
        "type": "object",
        "properties": ["names": ["type": "array", "items": ["type": "string"], "description": "Possible spellings of the name in Hebrew and English"]],
        "required": ["names"],
      ],
    ],
    [
      "name": "send_whatsapp",
      "description": "Prepare a WhatsApp message to a contact (opens WhatsApp with the text ready; Nave taps send).",
      "input_schema": [
        "type": "object",
        "properties": [
          "names": ["type": "array", "items": ["type": "string"]],
          "message": ["type": "string"],
        ],
        "required": ["names", "message"],
      ],
    ],
    [
      "name": "log_inventory",
      "description": "Record an inventory item (stone/lot/piece) with the current photo to the inventory sheet on Nave's PC.",
      "input_schema": [
        "type": "object",
        "properties": ["description": ["type": "string", "description": "e.g. 'Lot 12 — tanzanite, 3.2 ct, oval'"]],
        "required": ["description"],
      ],
    ],
    [
      "name": "save_note",
      "description": "Save a content idea or a note to Nave's PC (ideas list / notes).",
      "input_schema": [
        "type": "object",
        "properties": [
          "kind": ["type": "string", "enum": ["idea", "note"]],
          "text": ["type": "string"],
        ],
        "required": ["kind", "text"],
      ],
    ],
    [
      "name": "add_reminder",
      "description": "Create an Apple Reminder. Give due_at as local Israel time 'YYYY-MM-DDTHH:MM' computed from the context time, or in_minutes for relative requests.",
      "input_schema": [
        "type": "object",
        "properties": [
          "title": ["type": "string"],
          "due_at": ["type": "string", "description": "Local time YYYY-MM-DDTHH:MM (optional)"],
          "in_minutes": ["type": "integer", "description": "Minutes from now (optional)"],
          "notes": ["type": "string"],
        ],
        "required": ["title"],
      ],
    ],
    [
      "name": "list_reminders",
      "description": "List Nave's open (incomplete) Apple Reminders.",
      "input_schema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
      "name": "get_agenda",
      "description": "Read Nave's Apple Calendar events for a day. day_offset 0 = today, 1 = tomorrow.",
      "input_schema": [
        "type": "object",
        "properties": ["day_offset": ["type": "integer"]],
      ],
    ],
    [
      "name": "add_event",
      "description": "Add a calendar event. start_at as local Israel time YYYY-MM-DDTHH:MM.",
      "input_schema": [
        "type": "object",
        "properties": [
          "title": ["type": "string"],
          "start_at": ["type": "string"],
          "minutes": ["type": "integer", "description": "Duration, default 60"],
          "location": ["type": "string"],
        ],
        "required": ["title", "start_at"],
      ],
    ],
    [
      "name": "set_timer",
      "description": "Start a countdown timer; it chimes and announces in Nave's ear when done (and sends a notification).",
      "input_schema": [
        "type": "object",
        "properties": [
          "seconds": ["type": "integer"],
          "label": ["type": "string", "description": "Short Hebrew label, e.g. 'חומצה', 'ליטוש'"],
        ],
        "required": ["seconds"],
      ],
    ],
    [
      "name": "timers",
      "description": "Show running timers or cancel them all.",
      "input_schema": [
        "type": "object",
        "properties": ["action": ["type": "string", "enum": ["status", "cancel"]]],
      ],
    ],
    [
      "name": "remember_this",
      "description": "Save a visual memory: the current glasses frame + a short note + Nave's location and time. For 'remember that I parked here', 'remember I put X in Y'. Write the note in Hebrew as he said it, with the key object/place words.",
      "input_schema": [
        "type": "object",
        "properties": [
          "text": ["type": "string"],
          "with_photo": ["type": "boolean", "description": "Default true"],
        ],
        "required": ["text"],
      ],
    ],
    [
      "name": "recall_memory",
      "description": "Search saved memories by keywords (Hebrew/English). Returns matching notes with time, place and the photo of the best match. Empty query → newest memories.",
      "input_schema": [
        "type": "object",
        "properties": ["query": ["type": "string"]],
      ],
    ],
    [
      "name": "forget_memory",
      "description": "Delete a saved memory by its id (the 8-character id shown in brackets).",
      "input_schema": [
        "type": "object",
        "properties": ["id": ["type": "string"]],
        "required": ["id"],
      ],
    ],
    [
      "name": "navigate",
      "description": "Open Waze (or Apple Maps) with directions to a destination, or to a remembered spot (memory_id from recall_memory, e.g. the parked car).",
      "input_schema": [
        "type": "object",
        "properties": [
          "destination": ["type": "string"],
          "memory_id": ["type": "string"],
        ],
      ],
    ],
    [
      "name": "where_am_i",
      "description": "Get a fresh GPS location (place name + coordinates) and the current time.",
      "input_schema": ["type": "object", "properties": [:] as [String: Any]],
    ],
    [
      "name": "live_chat",
      "description": "Start or stop reading Nave's TikTok LIVE chat aloud into the glasses.",
      "input_schema": [
        "type": "object",
        "properties": ["action": ["type": "string", "enum": ["start", "stop"]]],
        "required": ["action"],
      ],
    ],
  ] }

  @MainActor
  func ask(history: [ChatTurn], question: String, imageJPEG: Data?) async throws -> String {
    guard !apiKey.isEmpty else { throw ClaudeError.missingKey }

    var messages: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
    var content: [[String: Any]] = []
    if let jpeg = imageJPEG { content.append(Self.imageBlock(jpeg)) }
    content.append(["type": "text", "text": question])
    messages.append(["role": "user", "content": content])

    for _ in 0..<6 {
      let json = try await send(messages)
      let blocks = json["content"] as? [[String: Any]] ?? []
      let stop = json["stop_reason"] as? String ?? ""
      messages.append(["role": "assistant", "content": blocks])

      if stop == "tool_use", let tools {
        var results: [[String: Any]] = []
        for block in blocks where block["type"] as? String == "tool_use" {
          let id = block["id"] as? String ?? ""
          let name = block["name"] as? String ?? ""
          let input = block["input"] as? [String: Any] ?? [:]
          let output = await tools.run(name: name, input: input)
          results.append(["type": "tool_result", "tool_use_id": id, "content": output])
        }
        messages.append(["role": "user", "content": results])
        continue
      }
      if stop == "pause_turn" { continue }

      let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
        .joined(separator: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw ClaudeError.empty }
      return text
    }
    throw ClaudeError.empty
  }

  /// Live facts appended to the system prompt on every request.
  @MainActor static var contextBlock: String {
    var lines = ["Context: now \(IsraelClock.nowLine)."]
    if let loc = LocationContext.shared.contextLine { lines.append(loc) }
    let timers = TimerAgent.shared.timers
    if !timers.isEmpty { lines.append("Running timers: \(timers.map(\.label).joined(separator: ", ")).") }
    let memories = VisualMemoryStore.shared.items.count
    if memories > 0 { lines.append("Saved visual memories: \(memories).") }
    return lines.joined(separator: " ")
  }

  static func imageBlock(_ jpeg: Data) -> [String: Any] {
    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
  }

  @MainActor
  private func send(_ messages: [[String: Any]]) async throws -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "max_tokens": 700,
      "system": Self.systemPrompt + "\n\n" + Self.contextBlock,
      "messages": messages,
    ]
    if tools != nil { body["tools"] = Self.toolDefinitions }

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 60
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      throw ClaudeError.http(code, String(data: data, encoding: .utf8) ?? "")
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeError.empty }
    return json
  }

  /// Downscale to ~1024px on the long side and JPEG-encode to keep uploads fast.
  @MainActor static func jpeg(_ image: UIImage, maxSide: CGFloat = 1024) -> Data? {
    let size = image.size
    let scale = min(1, maxSide / max(size.width, size.height))
    let target = CGSize(width: size.width * scale, height: size.height * scale)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: target))
    }
    return resized.jpegData(compressionQuality: 0.75)
  }
}
