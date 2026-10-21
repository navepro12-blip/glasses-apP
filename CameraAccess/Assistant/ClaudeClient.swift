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
    live translation, and workshop tools (silver price calculator, inventory logging, gemstone loupe mode).
    """

  let apiKey: String
  let model: String

  func ask(history: [ChatTurn], question: String, imageJPEG: Data?) async throws -> String {
    guard !apiKey.isEmpty else { throw ClaudeError.missingKey }

    var messages: [[String: Any]] = history.map { ["role": $0.role, "content": $0.text] }
    var content: [[String: Any]] = []
    if let jpeg = imageJPEG {
      content.append([
        "type": "image",
        "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
      ])
    }
    content.append(["type": "text", "text": question])
    messages.append(["role": "user", "content": content])

    let body: [String: Any] = [
      "model": model,
      "max_tokens": 500,
      "system": Self.systemPrompt,
      "messages": messages,
    ]

    var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 45
    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.httpBody = try JSONSerialization.data(withJSONObject: body)

    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      throw ClaudeError.http(code, String(data: data, encoding: .utf8) ?? "")
    }
    guard
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let blocks = json["content"] as? [[String: Any]]
    else { throw ClaudeError.empty }
    let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw ClaudeError.empty }
    return text
  }

  /// Downscale to ~1024px on the long side and JPEG-encode to keep uploads fast.
  @MainActor static func jpeg(_ image: UIImage) -> Data? {
    let maxSide: CGFloat = 1024
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
