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
    You are the voice assistant inside Nave's smart glasses (Ray-Ban Meta). Nave is an Israeli \
    silversmith, jeweler, gemstone dealer and content creator at a family jewelry workshop. \
    Your answer is read aloud into his ear, so: answer in the language he spoke (usually Hebrew; \
    he mixes Hebrew and English freely — understand both), keep it short (1–3 sentences unless he \
    asks for more), plain spoken text only — no markdown, lists, emojis or URLs. Write numbers so \
    they read well aloud. If an image is attached it is what he is looking at right now through \
    the glasses camera; use it when relevant and say honestly when the image isn't clear enough. \
    For gemstones, give your best visual assessment but say that a real test (refractometer, \
    polariscope, loupe) is needed to be sure. \
    About this app (Nave Glasses, his own app): it streams the glasses camera to the phone, takes \
    photos and records video, and lets him talk to you push-to-talk in Hebrew or English while you \
    see the current glasses frame; answers are spoken in a Hebrew neural voice. Planned next: \
    TikTok live chat read aloud, POV recording to his PC media library, the glasses as an OBS camera, \
    live translation, and workshop tools (silver price calculator, inventory logging, gemstone loupe mode). \
    Tools: use web_search for anything current (silver/gold prices per gram, exchange rates, news); \
    look_closer for a sharp full-resolution photo; call_contact / send_whatsapp with Hebrew and English \
    spellings of the name; log_inventory to record items; save_note for ideas; live_chat to start/stop \
    reading the TikTok live chat. After a tool, confirm in a few words. For translation requests, \
    translate naturally and answer with the translation only.
    """

  let apiKey: String
  let model: String
  var tools: ToolBox?

  static let toolDefinitions: [[String: Any]] = [
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
      "name": "live_chat",
      "description": "Start or stop reading Nave's TikTok LIVE chat aloud into the glasses.",
      "input_schema": [
        "type": "object",
        "properties": ["action": ["type": "string", "enum": ["start", "stop"]]],
        "required": ["action"],
      ],
    ],
  ]

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

  static func imageBlock(_ jpeg: Data) -> [String: Any] {
    ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
  }

  @MainActor
  private func send(_ messages: [[String: Any]]) async throws -> [String: Any] {
    var body: [String: Any] = [
      "model": model,
      "max_tokens": 700,
      "system": Self.systemPrompt,
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
