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

  /// Queued sentence with its audio being fetched ahead of time (prefetch), so
  /// the next sentence is ready while the current one plays.
  private struct Item {
    let text: String
    let audio: Task<Data?, Never>
    let enqueued: Date
  }

  private var queue: [Item] = []
  private var isSpeaking = false
  private var player: AVAudioPlayer?
  private let synth = AVSpeechSynthesizer()
  private var finish: CheckedContinuation<Void, Never>?
  /// Reference time for latency logging ("end of speech"); set by the view model.
  var traceStart: Date?
  private var loggedFirstPlayback = false

  /// Set when the last cloud voice request failed, so the UI can show why it fell back.
  private(set) var lastVoiceError: String?
  /// Words we spoke in the last ~30 s — used to ignore our own echo in the mic.
  private var spokenRecently: [(Date, Set<String>)] = []

  var recentlySpokenTokens: Set<String> {
    let cutoff = Date().addingTimeInterval(-30)
    spokenRecently.removeAll { $0.0 < cutoff }
    return spokenRecently.reduce(into: Set<String>()) { $0.formUnion($1.1) }
  }

  /// Words in `text` that we did NOT just say (i.e. the user talking over us).
  func newWordCount(_ text: String) -> Int {
    let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { WakeWord.normalize(String($0)) }
      .filter { $0.count >= 2 }
    let spoken = recentlySpokenTokens
    return words.filter { !spoken.contains($0) }.count
  }

  /// True when most of `text` was just spoken by us (echo through the glasses mic).
  func looksLikeEcho(_ text: String) -> Bool {
    let words = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { WakeWord.normalize(String($0)) }
      .filter { $0.count >= 2 }
    guard words.count >= 2 else { return false }
    let spoken = recentlySpokenTokens
    guard !spoken.isEmpty else { return false }
    let hits = words.filter { spoken.contains($0) }.count
    return Double(hits) / Double(words.count) >= 0.6
  }

  override init() {
    super.init()
    synth.delegate = self
  }

  func enqueue(_ text: String) {
    let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !clean.isEmpty else { return }
    // Start synthesis right away (prefetch); playback happens in order.
    let audio = Task { await self.fetchAudio(clean) }
    queue.append(Item(text: clean, audio: audio, enqueued: Date()))
    let tokens = clean.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { WakeWord.normalize(String($0)) }
    spokenRecently.append((Date(), Set(tokens)))
    // Flip the flag synchronously: two enqueues in the same tick must not
    // start two drain loops (they would fight over the single continuation).
    if !isSpeaking {
      isSpeaking = true
      Task { await drain() }
    }
  }

  func stopAll() {
    queue.forEach { $0.audio.cancel() }
    queue.removeAll()
    player?.stop()
    synth.stopSpeaking(at: .immediate)
    resume()
  }

  /// Marks the start of a new answer for latency logging.
  func beginTrace(at date: Date) {
    traceStart = date
    loggedFirstPlayback = false
  }

  var queuedCount: Int { queue.count }
  var isBusy: Bool { isSpeaking || !queue.isEmpty }
  /// True only while sound is really coming out (used to ignore our own voice).
  var isActuallyPlaying: Bool { (player?.isPlaying ?? false) || synth.isSpeaking }

  /// Waits until everything queued has been spoken (bounded).
  func waitUntilIdle(maxSeconds: Double = 60) async {
    let deadline = Date().addingTimeInterval(maxSeconds)
    while isBusy, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(150))
    }
  }

  private func drain() async {
    isSpeaking = true
    AudioRoute.activateForPlayback()
    let drainStart = Date()
    while !queue.isEmpty {
      if Date().timeIntervalSince(drainStart) > 120 {
        DiagLog.log("tts: watchdog — queue running for 2 min, dropping \(queue.count) items")
        queue.forEach { $0.audio.cancel() }
        queue.removeAll()
        break
      }
      let item = queue.removeFirst()
      let audio = await item.audio.value
      if Task.isCancelled { break }
      let waited = Int(Date().timeIntervalSince(item.enqueued) * 1000)
      Chime.stopThinking()
      if let audio {
        DiagLog.log("tts: play \(audio.count) bytes (ready \(waited) ms after enqueue)\(sinceTrace())")
        await play(audio)
      } else {
        DiagLog.log("tts: apple voice (\(waited) ms after enqueue)\(sinceTrace())")
        await speakWithApple(item.text)
      }
    }
    isSpeaking = false
  }

  private func sinceTrace() -> String {
    guard let traceStart, !loggedFirstPlayback else { return "" }
    loggedFirstPlayback = true
    return " — FIRST PLAYBACK \(Int(Date().timeIntervalSince(traceStart) * 1000)) ms after end of speech"
  }

  /// Fetches audio from the chosen provider; nil means "use the iPhone voice".
  private func fetchAudio(_ text: String) async -> Data? {
    let s = AssistantSettings.shared
    let t0 = Date()
    func ms() -> Int { Int(Date().timeIntervalSince(t0) * 1000) }
    do {
      let audio: Data?
      switch s.voiceProvider {
      case .apple:
        return nil
      case .pc:
        audio = try await PCVoiceTTS.synthesize(text: text, baseURL: s.pcURL, voice: s.pcVoice)
      case .azure:
        audio = try await AzureTTS.synthesize(
          text: text, key: s.azureKey, region: s.azureRegion, hebrewVoice: s.hebrewVoice.rawValue)
      case .eleven:
        audio = try await ElevenTTS.synthesize(text: text, key: s.elevenKey, voiceID: s.elevenVoiceID)
      case .gemini:
        audio = try await GeminiTTS.synthesize(text: text, key: s.geminiKey, voice: s.geminiVoice)
      }
      lastVoiceError = nil
      DiagLog.log("tts: \(s.voiceProvider.rawValue) \(text.count) chars → \(audio?.count ?? 0) bytes in \(ms()) ms")
      return audio
    } catch {
      lastVoiceError = error.localizedDescription
      DiagLog.log("tts: \(s.voiceProvider.rawValue) failed after \(ms()) ms: \(error.localizedDescription)")
      return nil
    }
  }

  /// Awaits `finish`, but never forever: a player/synth that fails to call
  /// back would otherwise hang the queue (and everything that checks isBusy).
  private func awaitFinish(timeoutSeconds: Double, start: () -> Void) async {
    // Never leave an earlier continuation dangling.
    resume()
    let timeout = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(timeoutSeconds))
      self?.resume()
    }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      finish = c
      start()
    }
    timeout.cancel()
  }

  private func play(_ data: Data) async {
    guard let p = try? AVAudioPlayer(data: data) else {
      DiagLog.log("tts: AVAudioPlayer could not decode the audio")
      return
    }
    player = p
    p.delegate = self
    let seconds = max(5, p.duration + 4)
    await awaitFinish(timeoutSeconds: seconds) {
      if !p.play() { resume() }
    }
    player = nil
  }

  private func speakWithApple(_ text: String) async {
    let utterance = AVSpeechUtterance(string: text)
    let lang = TextLanguage.isHebrew(text) ? "he-IL" : "en-US"
    utterance.voice = Self.bestVoice(for: lang)
    utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
    let seconds = max(6, Double(text.count) * 0.12 + 3)
    await awaitFinish(timeoutSeconds: seconds) {
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

/// Free local Hebrew voice (BlueTTS) running on Nave's PC — see pc-voice-server/.
@MainActor
enum PCVoiceTTS {
  /// When the PC isn't reachable (away from home Wi-Fi), skip it for a minute
  /// instead of waiting on every sentence.
  private static var downUntil = Date.distantPast
  private static var lastOK = Date.distantPast

  static func synthesize(text: String, baseURL: String, voice: String) async throws -> Data {
    guard Date() >= downUntil else { throw TTSFailure(message: "המחשב לא זמין כרגע — קול גיבוי") }
    var base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !base.isEmpty else { throw TTSFailure(message: "חסרה כתובת המחשב") }
    if !base.hasPrefix("http") { base = "http://" + base }
    if base.hasSuffix("/") { base.removeLast() }
    guard let url = URL(string: base + "/tts") else { throw TTSFailure(message: "כתובת מחשב לא תקינה") }
    // Quick reachability probe if we haven't heard from the PC lately.
    if Date().timeIntervalSince(lastOK) > 60, let health = URL(string: base + "/health") {
      var probe = URLRequest(url: health)
      probe.timeoutInterval = 1.5
      let ok = ((try? await URLSession.shared.data(for: probe))?.1 as? HTTPURLResponse)?.statusCode == 200
      guard ok else {
        downUntil = Date().addingTimeInterval(60)
        DiagLog.log("tts: PC unreachable — using backup voice for 60 s")
        throw TTSFailure(message: "המחשב לא זמין — קול גיבוי")
      }
      lastOK = Date()
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    // BlueTTS on the PC's CPU takes ~3–4 s per sentence; GPU is faster.
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text, "voice": voice])
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      let code = (response as? HTTPURLResponse)?.statusCode ?? 0
      guard code == 200, !data.isEmpty else { throw TTSFailure(message: "שרת הקול במחשב החזיר \(code)") }
      lastOK = Date()
      return data
    } catch let e as TTSFailure {
      throw e
    } catch {
      downUntil = Date().addingTimeInterval(60)
      throw TTSFailure(message: "אין חיבור לשרת הקול במחשב — הוא דלוק? אותה רשת Wi-Fi?")
    }
  }
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
  /// The mic's format, waiting briefly while Bluetooth settles (0 Hz = not ready).
  @MainActor static func validInputFormat(_ node: AVAudioInputNode) async -> AVAudioFormat? {
    for _ in 0..<8 {
      let f = node.outputFormat(forBus: 0)
      if f.sampleRate > 0, f.channelCount > 0 { return f }
      try? await Task.sleep(for: .milliseconds(250))
    }
    return nil
  }

  /// True while the wake-word listener owns the mic. The recorder checks this
  /// before deactivating the shared session when a recording stops.
  nonisolated(unsafe) private static var _assistantListening = false
  private static let flagLock = NSLock()
  static var assistantListening: Bool {
    get { flagLock.lock(); defer { flagLock.unlock() }; return _assistantListening }
    set { flagLock.lock(); _assistantListening = newValue; flagLock.unlock() }
  }

  static func activateForPlayback() {
    configure(preferPhoneMic: nil)
  }

  /// Releases the shared session so iOS drops the orange microphone indicator.
  static func deactivate(reason: String) {
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      lastActivation = .distantPast
      DiagLog.log("mic: CLOSED — session deactivated (\(reason))")
    } catch {
      DiagLog.log("mic: deactivate failed (\(reason)): \(error.localizedDescription)")
    }
  }

  static func activateForListening(preferPhoneMic: Bool = false) {
    configure(preferPhoneMic: preferPhoneMic)
  }

  private static let options: AVAudioSession.CategoryOptions = [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers, .duckOthers]

  nonisolated(unsafe) private static var lastActivation = Date.distantPast

  /// Sets the category only when it actually differs — every setCategory call
  /// restarts running audio engines, which cost us the listener each time —
  /// and re-activates at most every few seconds.
  private static func configure(preferPhoneMic: Bool?) {
    let session = AVAudioSession.sharedInstance()
    do {
      // iOS normalises the options it reports, so compare as a superset —
      // an exact compare made us call setCategory on every listen, which
      // renegotiated Bluetooth HFP and failed ('!int' / 'what').
      if session.category != .playAndRecord || session.mode != .default
        || !session.categoryOptions.isSuperset(of: options)
      {
        DiagLog.log("audio: setCategory playAndRecord (was \(session.category.rawValue)/\(session.mode.rawValue))")
        try session.setCategory(.playAndRecord, mode: .default, options: options)
        lastActivation = .distantPast
      }
      if let preferPhoneMic {
        let inputs = session.availableInputs ?? []
        let wantedType: AVAudioSession.Port = preferPhoneMic ? .builtInMic : .bluetoothHFP
        let wanted = inputs.first(where: { $0.portType == wantedType })
        let current = session.preferredInput?.uid
        if let wanted, current != wanted.uid {
          DiagLog.log("audio: preferred input → \(wanted.portName)")
          try session.setPreferredInput(wanted)
        } else if wanted == nil, !preferPhoneMic, current != nil {
          try session.setPreferredInput(nil)
        }
      }
      if Date().timeIntervalSince(lastActivation) > 5 {
        try session.setActive(true)
        lastActivation = Date()
      }
    } catch {
      DiagLog.log("audio: session error \(error.localizedDescription)")
    }
  }
}
