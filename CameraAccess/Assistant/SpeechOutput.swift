//
// SpeechOutput.swift
// Speaks text into the glasses (they're the phone's Bluetooth audio route).
// Primary: Azure Neural Hebrew voices (Hila / Avri) — the most natural Hebrew
// with low latency. Fallback: the best installed iOS voice (free, offline).
// Utterances queue, so a burst of messages is read one after another.
//

@preconcurrency import AVFoundation
import Foundation

@MainActor
final class SpeechOutput: NSObject {
  static let shared = SpeechOutput()

  private var queue: [String] = []
  private var isSpeaking = false
  private var player: AVAudioPlayer?
  private let synth = AVSpeechSynthesizer()
  private var finish: CheckedContinuation<Void, Never>?

  /// Set when the last cloud voice request failed, so the UI can show why it fell back.
  private(set) var lastVoiceError: String?

  override init() {
    super.init()
    synth.delegate = self
  }

  func enqueue(_ text: String) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    queue.append(clean)
    if !isSpeaking { Task { await drain() } }
  }

  func stopAll() {
    queue.removeAll()
    player?.stop()
    synth.stopSpeaking(at: .immediate)
    resume()
  }

  var queuedCount: Int { queue.count }
  var isBusy: Bool { isSpeaking || !queue.isEmpty }

  private func drain() async {
    isSpeaking = true
    AudioRoute.activateForPlayback()
    while !queue.isEmpty {
      let text = queue.removeFirst()
      await speakOne(text)
    }
    isSpeaking = false
  }

  private func speakOne(_ text: String) async {
    let s = AssistantSettings.shared
    do {
      let audio: Data?
      switch s.voiceProvider {
      case .apple:
        audio = nil
      case .azure:
        audio = try await AzureTTS.synthesize(
          text: text, key: s.azureKey, region: s.azureRegion, hebrewVoice: s.hebrewVoice.rawValue)
      case .eleven:
        audio = try await ElevenTTS.synthesize(text: text, key: s.elevenKey, voiceID: s.elevenVoiceID)
      case .gemini:
        audio = try await GeminiTTS.synthesize(text: text, key: s.geminiKey, voice: s.geminiVoice)
      }
      if let audio {
        lastVoiceError = nil
        await play(audio)
        return
      }
    } catch {
      lastVoiceError = error.localizedDescription
    }
    await speakWithApple(text)
  }

  private func play(_ data: Data) async {
    guard let p = try? AVAudioPlayer(data: data) else { return }
    player = p
    p.delegate = self
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      finish = c
      if !p.play() { resume() }
    }
    player = nil
  }

  private func speakWithApple(_ text: String) async {
    let utterance = AVSpeechUtterance(string: text)
    let lang = TextLanguage.isHebrew(text) ? "he-IL" : "en-US"
    utterance.voice = Self.bestVoice(for: lang)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      finish = c
      synth.speak(utterance)
    }
  }

  /// Highest-quality installed voice for a language (Premium > Enhanced > Default).
  /// Better Hebrew voices can be downloaded in iOS Settings → Accessibility →
  /// Spoken Content → Voices → Hebrew.
  static func bestVoice(for lang: String) -> AVSpeechSynthesisVoice? {
    let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == lang }
    return voices.max { $0.quality.rawValue < $1.quality.rawValue }
      ?? AVSpeechSynthesisVoice(language: lang)
  }

  fileprivate func resume() {
    let c = finish
    finish = nil
    c?.resume()
  }
}

extension SpeechOutput: AVAudioPlayerDelegate {
  nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
    Task { @MainActor in self.resume() }
  }
  nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
    Task { @MainActor in self.resume() }
  }
}

extension SpeechOutput: AVSpeechSynthesizerDelegate {
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in self.resume() }
  }
  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in self.resume() }
  }
}

enum TextLanguage {
  static func isHebrew(_ text: String) -> Bool {
    var hebrew = 0
    var latin = 0
    for scalar in text.unicodeScalars {
      if (0x0590...0x05FF).contains(scalar.value) { hebrew += 1 }
      else if CharacterSet.letters.contains(scalar), scalar.isASCII { latin += 1 }
    }
    return hebrew > 0 && hebrew >= latin / 3
  }
}

enum AzureTTS {
  struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static func synthesize(text: String, key: String, region: String, hebrewVoice: String) async throws -> Data {
    let hebrew = TextLanguage.isHebrew(text)
    let voice = hebrew ? hebrewVoice : "en-US-AvaMultilingualNeural"
    let lang = hebrew ? "he-IL" : "en-US"
    let ssml = """
      <speak version="1.0" xml:lang="\(lang)"><voice name="\(voice)">\(escape(text))</voice></speak>
      """
    let host = region.isEmpty ? "westeurope" : region
    var request = URLRequest(url: URL(string: "https://\(host).tts.speech.microsoft.com/cognitiveservices/v1")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue(key, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
    request.setValue("application/ssml+xml", forHTTPHeaderField: "Content-Type")
    request.setValue("audio-24khz-96kbitrate-mono-mp3", forHTTPHeaderField: "X-Microsoft-OutputFormat")
    request.setValue("NaveGlasses", forHTTPHeaderField: "User-Agent")
    request.httpBody = Data(ssml.utf8)
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200, !data.isEmpty else {
      throw Failure(message: "Azure TTS \(code) — בדוק מפתח ואזור (region)")
    }
    return data
  }

  private static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
      .replacingOccurrences(of: "'", with: "&apos;")
  }
}

struct TTSFailure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// ElevenLabs v3 — the most natural Hebrew of the cloud options (slower, paid
/// beyond the free monthly quota). Must use `language_code: he` with v3.
enum ElevenTTS {
  static func synthesize(text: String, key: String, voiceID: String) async throws -> Data {
    guard !key.isEmpty else { throw TTSFailure(message: "חסר מפתח ElevenLabs") }
    let id = voiceID.isEmpty ? "21m00Tcm4TlvDq8ikWAM" : voiceID
    var request = URLRequest(
      url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(id)?output_format=mp3_44100_128")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue(key, forHTTPHeaderField: "xi-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    var body: [String: Any] = ["text": text, "model_id": "eleven_v3"]
    if TextLanguage.isHebrew(text) { body["language_code"] = "he" }
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200, !data.isEmpty else {
      let msg = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
      throw TTSFailure(message: "ElevenLabs \(code): \(msg)")
    }
    return data
  }
}

/// Gemini TTS (Google AI Studio key). Returns 24 kHz 16-bit mono PCM, wrapped
/// here in a WAV header so AVAudioPlayer can play it.
enum GeminiTTS {
  static func synthesize(text: String, key: String, voice: String) async throws -> Data {
    guard !key.isEmpty else { throw TTSFailure(message: "חסר מפתח Gemini") }
    let model = "gemini-2.5-flash-preview-tts"
    var request = URLRequest(
      url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!)
    request.httpMethod = "POST"
    request.timeoutInterval = 30
    request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    let body: [String: Any] = [
      "contents": [["parts": [["text": text]]]],
      "generationConfig": [
        "responseModalities": ["AUDIO"],
        "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voice.isEmpty ? "Kore" : voice]]],
      ],
    ]
    request.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (data, response) = try await URLSession.shared.data(for: request)
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200,
      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]],
      let content = candidates.first?["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      let inline = parts.compactMap({ $0["inlineData"] as? [String: Any] }).first,
      let b64 = inline["data"] as? String,
      let pcm = Data(base64Encoded: b64)
    else {
      let msg = String(data: data, encoding: .utf8)?.prefix(160) ?? ""
      throw TTSFailure(message: "Gemini \(code): \(msg)")
    }
    return wav(pcm: pcm, sampleRate: 24000)
  }

  static func wav(pcm: Data, sampleRate: UInt32, channels: UInt16 = 1, bits: UInt16 = 16) -> Data {
    var d = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
    let byteRate = sampleRate * UInt32(channels) * UInt32(bits / 8)
    d.append(Data("RIFF".utf8)); u32(36 + UInt32(pcm.count)); d.append(Data("WAVE".utf8))
    d.append(Data("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(sampleRate); u32(byteRate)
    u16(channels * bits / 8); u16(bits)
    d.append(Data("data".utf8)); u32(UInt32(pcm.count)); d.append(pcm)
    return d
  }
}

/// Audio session: play and record over Bluetooth so the glasses are both the
/// mic (HFP) and the speaker.
enum AudioRoute {
  static func activateForPlayback() {
    configure()
  }

  static func activateForListening() {
    configure()
  }

  private static func configure() {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playAndRecord, mode: .default,
        options: [.allowBluetooth, .allowBluetoothA2DP, .duckOthers])
      try session.setActive(true)
    } catch {
      NSLog("[NaveGlasses] audio session error: \(error)")
    }
  }
}
