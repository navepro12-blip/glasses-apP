//
// WakeWordListener.swift
// Hands-free: listens continuously (glasses mic over Bluetooth) for "קלוד" /
// "Claude". Whatever follows the wake word in the same breath becomes the
// question: "קלוד, מה האבן הזאת?". Saying only the wake word opens a short
// window for the question.
//
// Robustness notes (these were the crash / "deaf" sources):
// - A fresh AVAudioEngine is created for every listening attempt. Reusing one
//   engine across Bluetooth route changes (A2DP ↔ HFP, glasses on/off) leaves
//   it with a stale hardware format, and installTap/start then raise an
//   Objective-C exception that kills the app.
// - Starting an engine on the HFP mic *itself* changes the route (output moves
//   from A2DP to HFP). Restarting on every route change therefore looped once a
//   second, tearing recognition down before any result arrived and lagging the
//   whole app. Now a route change only restarts when the input port changed.
// - Restarts are rate-limited (≥ 1 s apart) with exponential backoff when the
//   recogniser keeps failing early, and everything is logged to DiagLog.
// - HFP audio is 8/16 kHz; buffers are converted to 16 kHz mono before they go
//   to the recogniser.
//

@preconcurrency import AVFoundation
import UIKit
import Foundation
@preconcurrency import Speech

@MainActor
final class WakeWordListener {
  /// A full command was heard ("קלוד <question>").
  var onCommand: (@MainActor (String) -> Void)?
  /// Only the wake word was heard; the caller should listen for the question.
  var onWakeOnly: (@MainActor () -> Void)?
  /// Live text after the wake word, for the on-screen transcript.
  var onPartial: (@MainActor (String) -> Void)?
  /// Everything currently being heard (before the wake word too), for feedback.
  var onRaw: (@MainActor (String) -> Void)?
  /// Fired once when the wake word is first detected.
  var onWake: (@MainActor () -> Void)?
  /// Human-readable state for the on-screen diagnostics line.
  var onStatus: (@MainActor (String) -> Void)?

  private(set) var isRunning = false
  private var observers: [NSObjectProtocol] = []
  private var language: ListenLanguage = .hebrew
  private var engine: AVAudioEngine?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var generation = 0
  private var armed = false
  private var command = ""
  private var silenceTask: Task<Void, Never>?
  private var recycleTask: Task<Void, Never>?
  private var restartTask: Task<Void, Never>?
  private var lastBegin = Date.distantPast
  private var partialCount = 0
  /// Recogniser sessions that ended with no result shortly after starting.
  private var earlyFailures = 0
  private var inputUID = ""
  /// Set after repeated failures on the glasses mic: use the iPhone mic instead.
  private(set) var fellBackToPhoneMic = false
  private var armedAt = Date.distantPast
  private var hardStopTask: Task<Void, Never>?
  private var loggedIgnoreReason = ""
  /// The engine stays running between questions so the Bluetooth route (HFP)
  /// doesn't flap A2DP ↔ HFP on every answer — each flip costs 1–2 s.
  private var heldFormat: AVAudioFormat?

  func start(language: ListenLanguage) async throws {
    guard !isRunning else { return }
    // Mark running *before* the permission await so a stop() that arrives in
    // the meantime is honoured (otherwise two listeners end up on the mic).
    isRunning = true
    self.language = language
    let ok = await SpeechInput.requestAuthorization()
    guard isRunning else { return }
    guard ok else {
      isRunning = false
      throw SpeechInput.InputError.notAuthorized
    }
    AudioRoute.assistantListening = true
    observeAudioChanges()
    earlyFailures = 0
    DiagLog.log("wake: start lang=\(language.rawValue)")
    try beginRecognition()
  }

  /// Stops recognising. With `keepRoute` the audio engine keeps running (no
  /// tap) so the glasses stay on the HFP route while Claude thinks and talks.
  func stop(keepRoute: Bool = false) {
    if isRunning { DiagLog.log("wake: stop keepRoute=\(keepRoute)") }
    isRunning = false
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    silenceTask?.cancel()
    recycleTask?.cancel()
    restartTask?.cancel()
    hardStopTask?.cancel()
    silenceTask = nil
    recycleTask = nil
    restartTask = nil
    hardStopTask = nil
    tearDown(keepEngine: keepRoute)
    if !keepRoute { AudioRoute.assistantListening = false }
  }

  /// Fully releases the microphone (app to background, listening switched off).
  func releaseEngine() {
    stop(keepRoute: false)
  }

  // MARK: - Audio route / engine changes

  private func observeAudioChanges() {
    guard observers.isEmpty else { return }
    let nc = NotificationCenter.default

    // Route change: only matters when the *input* port changed (e.g. glasses
    // disconnected). Our own engine start flips the output to HFP, which must
    // not trigger a restart.
    observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { [weak self] note in
      let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
      let newInput = AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid ?? ""
      Task { @MainActor in
        guard let self, self.isRunning else { return }
        let engineAlive = self.engine?.isRunning ?? false
        if newInput != self.inputUID || !engineAlive {
          DiagLog.log("wake: input changed (reason \(reason)) '\(self.inputUID)' → '\(newInput)' engineRunning=\(engineAlive)")
          self.scheduleRestart(after: .milliseconds(800), reason: "המיקרופון השתנה — מתחבר מחדש…")
        }
      }
    })

    // The system stopped *our* engine (format/route reconfiguration).
    observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] note in
      let changedID = ObjectIdentifier(note.object as AnyObject)
      Task { @MainActor in
        guard let self, self.isRunning, let engine = self.engine, ObjectIdentifier(engine) == changedID else { return }
        DiagLog.log("wake: our engine was reconfigured by the system")
        self.scheduleRestart(after: .milliseconds(800), reason: "מתחבר מחדש למיקרופון…")
      }
    })

    // Interruption ended (phone call, Siri…) → resume.
    observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { [weak self] note in
      let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
      Task { @MainActor in
        guard let self, self.isRunning else { return }
        if type == AVAudioSession.InterruptionType.ended.rawValue {
          self.scheduleRestart(after: .milliseconds(600), reason: "ממשיך להקשיב…")
        } else {
          self.onStatus?("הופסק זמנית (שיחה/סירי)")
        }
      }
    })

    let plainRestart: @Sendable (Notification) -> Void = { [weak self] _ in
      Task { @MainActor in self?.scheduleRestart(after: .milliseconds(800), reason: "מתחבר מחדש למיקרופון…") }
    }
    observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil, using: plainRestart))
    observers.append(nc.addObserver(forName: .glassesAudioSessionReleased, object: nil, queue: nil, using: plainRestart))
  }

  /// Coalesces restart requests and keeps them ≥ 1 s apart.
  private func scheduleRestart(after delay: Duration, reason: String?) {
    guard isRunning, !armed else { return }
    restartTask?.cancel()
    let sinceLast = Date().timeIntervalSince(lastBegin)
    let minGap: Duration = .milliseconds(Int(max(0, 1.0 - sinceLast) * 1000))
    let wait = delay > minGap ? delay : minGap
    restartTask = Task { [weak self] in
      try? await Task.sleep(for: wait)
      guard let self, !Task.isCancelled, self.isRunning, !self.armed else { return }
      if let reason { self.onStatus?(reason) }
      self.beginRecognitionSafely()
    }
  }

  private func beginRecognitionSafely() {
    do {
      try beginRecognition()
    } catch {
      earlyFailures += 1
      DiagLog.log("wake: begin failed (\(earlyFailures)): \(error.localizedDescription)")
      onStatus?("המיקרופון לא זמין — מנסה שוב")
      scheduleRestart(after: .seconds(backoffSeconds), reason: nil)
    }
  }

  /// 2, 4, 8, 16, 30 s…
  private var backoffSeconds: Int { min(30, 1 << min(earlyFailures, 5)) }

  // MARK: - Recognition

  private func beginRecognition() throws {
    tearDown(keepEngine: true)
    guard isRunning else { return }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
      recognizer.isAvailable
    else {
      DiagLog.log("wake: recognizer unavailable for \(language.rawValue)")
      throw SpeechInput.InputError.unavailable
    }

    armed = false
    command = ""
    partialCount = 0
    generation += 1
    let gen = generation
    lastBegin = Date()

    // After repeated failures on the glasses mic, fall back to the iPhone mic.
    let preferPhone = AssistantSettings.shared.micSource == .phone
      || (AssistantSettings.shared.micSource == .auto && fellBackToPhoneMic)
    AudioRoute.activateForListening(preferPhoneMic: preferPhone)

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    req.requiresOnDeviceRecognition = false
    req.taskHint = .dictation
    req.contextualStrings = WakeWord.contextualStrings
    request = req

    // Reuse the engine held running since the last question when its format
    // is unchanged (keeps the HFP route up); otherwise build a fresh one.
    var reused = false
    if let held = engine, held.isRunning, let heldFormat {
      let now = held.inputNode.outputFormat(forBus: 0)
      if now.sampleRate == heldFormat.sampleRate, now.channelCount == heldFormat.channelCount, now.sampleRate > 0 {
        reused = true
      } else {
        held.inputNode.removeTap(onBus: 0)
        held.stop()
        engine = nil
        self.heldFormat = nil
      }
    }
    let activeEngine: AVAudioEngine
    let format: AVAudioFormat
    if reused, let held = engine {
      activeEngine = held
      format = held.inputNode.outputFormat(forBus: 0)
      Self.installTap(on: held.inputNode, format: format, request: req)
    } else {
      let newEngine = AVAudioEngine()
      let input = newEngine.inputNode
      format = input.outputFormat(forBus: 0)
      // While Bluetooth is switching the mic reports 0 Hz — installing a tap
      // then crashes the app. Retry shortly instead.
      guard format.sampleRate > 0, format.channelCount > 0 else {
        request = nil
        DiagLog.log("wake: input format 0 Hz, retrying")
        onStatus?("ממתין למיקרופון…")
        scheduleRestart(after: .milliseconds(900), reason: nil)
        return
      }
      engine = newEngine
      heldFormat = format
      Self.installTap(on: input, format: format, request: req)
      newEngine.prepare()
      do {
        try newEngine.start()
      } catch {
        newEngine.inputNode.removeTap(onBus: 0)
        engine = nil
        heldFormat = nil
        request = nil
        throw error
      }
      activeEngine = newEngine
    }
    _ = activeEngine
    let port = AVAudioSession.sharedInstance().currentRoute.inputs.first
    inputUID = port?.uid ?? ""
    let route = port?.portName ?? "?"
    loggedIgnoreReason = ""
    DiagLog.log("wake: engine \(reused ? "reused" : "started") gen=\(gen) fmt=\(Int(format.sampleRate))Hz/\(format.channelCount)ch input=\(route)/\(port?.portType.rawValue ?? "?") \(DiagLog.sessionLine())")
    onStatus?("👂 מקשיב דרך: \(route)\(fellBackToPhoneMic ? " (אייפון)" : "")")

    let started = Date()
    task = Self.makeTask(recognizer: recognizer, request: req) { [weak self] text, ended, errorText in
      Task { @MainActor in
        guard let self, self.generation == gen, self.isRunning else { return }
        if !text.isEmpty {
          self.partialCount += 1
          if self.partialCount == 1 {
            DiagLog.log("wake: first partial after \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(text.prefix(40))")
          }
          self.handle(text, final: ended && errorText == nil)
        }
        if ended {
          let life = Date().timeIntervalSince(started)
          DiagLog.log("wake: task ended after \(Int(life)) s, partials=\(self.partialCount)\(errorText.map { " error=\($0)" } ?? "")")
          self.taskEnded(lifetime: life)
        }
      }
    }

    // Server-side recognition caps a request at about a minute; recycle it
    // while idle so listening never silently stops.
    recycleTask?.cancel()
    recycleTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(50))
      guard let self, !Task.isCancelled, self.isRunning, !self.armed, self.generation == gen else { return }
      DiagLog.log("wake: recycling session")
      self.beginRecognitionSafely()
    }
  }

  private func taskEnded(lifetime: TimeInterval) {
    guard isRunning, !armed else { return }
    if partialCount == 0, lifetime < 8 {
      earlyFailures += 1
      let onGlasses = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType == .bluetoothHFP
      if earlyFailures >= 3, onGlasses, !fellBackToPhoneMic, AssistantSettings.shared.micSource == .auto {
        fellBackToPhoneMic = true
        earlyFailures = 0
        DiagLog.log("wake: glasses mic gave nothing 3× — falling back to the iPhone mic")
        onStatus?("המיקרופון של המשקפיים לא מגיב — עובר למיקרופון של האייפון")
        scheduleRestart(after: .seconds(1), reason: nil)
        return
      }
      onStatus?("זיהוי הדיבור נכשל (\(earlyFailures)) — מנסה שוב בעוד \(backoffSeconds) שניות")
      scheduleRestart(after: .seconds(backoffSeconds), reason: nil)
    } else {
      earlyFailures = 0
      scheduleRestart(after: .milliseconds(300), reason: nil)
    }
  }

  private func handle(_ text: String, final: Bool) {
    onRaw?(String(text.suffix(60)))
    // Don't wake on our own voice (answers / live chat read aloud) — but only
    // while audio is really playing, never because of a stuck flag.
    if !armed, SpeechOutput.shared.isActuallyPlaying {
      logIgnored("speaking (our own voice is playing)")
      return
    }
    guard let tail = WakeWord.commandAfterWakeWord(in: text) else {
      logIgnored("no wake word in '\(text.suffix(30))'")
      return
    }
    if !armed {
      DiagLog.log("wake: MATCHED in '\(text.suffix(40))' tail='\(tail)'")
      armed = true
      armedAt = Date()
      onWake?()
      // Hard cap: never wait more than 7 s after the wake word even if the
      // recogniser keeps revising the text.
      hardStopTask?.cancel()
      hardStopTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(7))
        guard let self, !Task.isCancelled, self.isRunning, self.armed else { return }
        DiagLog.log("wake: hard cap reached — sending")
        self.fire()
      }
    }
    let changed = tail != command
    command = tail
    onPartial?(command)

    if final {
      DiagLog.log("wake: recogniser final — sending")
      fire()
      return
    }
    // Finish when the speaker pauses: 0.9 s after the last *change* with a
    // question, or 2.5 s if only the wake word was said. Identical re-sent
    // partials don't reset the timer.
    guard changed || silenceTask == nil else { return }
    silenceTask?.cancel()
    let wait: Duration = command.isEmpty ? .milliseconds(2500) : .milliseconds(900)
    silenceTask = Task { [weak self] in
      try? await Task.sleep(for: wait)
      guard let self, !Task.isCancelled, self.isRunning, self.armed else { return }
      self.fire()
    }
  }

  /// Delivers the captured command (or wake-only) exactly once.
  private func fire() {
    guard isRunning, armed else { return }
    let heard = command
    DiagLog.log("wake: command '\(heard)' \(Int(Date().timeIntervalSince(armedAt) * 1000)) ms after wake")
    stop(keepRoute: true)
    if heard.isEmpty { onWakeOnly?() } else { onCommand?(heard) }
  }

  private func logIgnored(_ reason: String) {
    // One line per reason per session, so the log isn't flooded by partials.
    let key = String(reason.prefix(12))
    guard key != loggedIgnoreReason else { return }
    loggedIgnoreReason = key
    DiagLog.log("wake: ignored — \(reason)")
  }

  private func tearDown(keepEngine: Bool = false) {
    task?.cancel()
    task = nil
    request?.endAudio()
    request = nil
    guard let engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    if keepEngine, engine.isRunning { return }
    if engine.isRunning { engine.stop() }
    self.engine = nil
    heldFormat = nil
  }

  // Built outside the main actor: the tap and result blocks run on audio /
  // speech threads, and Swift 6 would otherwise trap on the isolation check.
  nonisolated private static func installTap(
    on node: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest
  ) {
    nonisolated(unsafe) let req = request
    let converter = SpeechAudio.converter(from: format)
    node.removeTap(onBus: 0)
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      if let converter, let out = SpeechAudio.convert(buffer, with: converter) {
        req.append(out)
      } else {
        req.append(buffer)
      }
    }
  }

  nonisolated private static func makeTask(
    recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
    onResult: @escaping @Sendable (String, Bool, String?) -> Void
  ) -> SFSpeechRecognitionTask {
    recognizer.recognitionTask(with: request) { result, error in
      if let result {
        onResult(result.bestTranscription.formattedString, result.isFinal, nil)
      } else if let error {
        let ns = error as NSError
        onResult("", true, "\(ns.domain)#\(ns.code) \(ns.localizedDescription)")
      }
    }
  }
}

/// Converts the hardware input (HFP is 8 or 16 kHz, sometimes stereo on the
/// phone) to 16 kHz mono Float32 — the format the recogniser is happiest with.
enum SpeechAudio {
  nonisolated static func targetFormat() -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
  }

  nonisolated static func converter(from format: AVAudioFormat) -> AVAudioConverter? {
    if format.sampleRate == 16000, format.channelCount == 1 { return nil }
    return AVAudioConverter(from: format, to: targetFormat())
  }

  nonisolated static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
    let target = converter.outputFormat
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, outStatus in
      if consumed {
        outStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, out.frameLength > 0 else { return nil }
    return out
  }
}

/// Matching the wake word the way Apple's Hebrew recogniser actually spells it.
enum WakeWord {
  static let contextualStrings = ["קלוד", "היי קלוד", "הי קלוד", "Claude", "hey Claude"]

  /// Exact spellings (normalised: lowercase, no geresh/quotes/nikud).
  static let exact: Set<String> = [
    "קלוד", "קלאוד", "קלוט", "קלאד", "קלודה", "קלודי", "כלוד", "קלווד", "גלוד", "קלאודי",
    "claude", "cloud", "clod", "claud", "klod", "klaud", "clawed", "clode", "cloude", "glaud",
  ]

  /// Does one spoken token sound like the name? ("היי"/"hey" before it is simply skipped.)
  static func isWakeToken(_ raw: String) -> Bool {
    let t = normalize(raw)
    guard !t.isEmpty else { return false }
    if exact.contains(t) { return true }
    // Hebrew: ק/כ/ג + ל + 0–2 vowels (א/ו) + ד/ט [+ optional ה/י]
    if t.range(of: "^[קכג]ל[או]{0,2}[דט][הי]?$", options: .regularExpression) != nil { return true }
    // Latin: (c|k|g)l + vowel cluster + d(e)
    if t.range(of: "^[ckg]l(a|o|au|ou|aw|oa)+(d|de|t)$", options: .regularExpression) != nil { return true }
    return false
  }

  /// Looser spellings the recogniser produces ("כלום", "קלו", "קולד") — accepted
  /// only when a question follows, so everyday words don't wake us by themselves.
  static func isLenientWakeToken(_ raw: String) -> Bool {
    let t = normalize(raw)
    return t.range(of: "^[קכג][וא]?ל[אוי]{0,2}([דטם][הי]?)?$", options: .regularExpression) != nil
      || t.range(of: "^[ckg](o|a)?l(a|o|u|au|ou|aw|oa)*(d|de|t|m)?$", options: .regularExpression) != nil && t.count >= 3
  }

  /// Returns the text after the (last) wake word, or nil if it wasn't said.
  /// The command is trimmed of punctuation; an empty string means "name only".
  static func commandAfterWakeWord(in text: String) -> String? {
    let tokens = text.split(whereSeparator: { $0.isWhitespace || ",.!?:;״\"'".contains($0) })
      .map(String.init)
    var found = tokens.lastIndex(where: isWakeToken)
    if found == nil, tokens.count >= 2 {
      // Lenient spelling followed by at least two more words.
      found = tokens.indices.dropLast(2).last(where: { isLenientWakeToken(tokens[$0]) })
    }
    guard let idx = found else { return nil }
    let tail = tokens[(idx + 1)...].joined(separator: " ")
    return tail.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?:–-;").union(.whitespacesAndNewlines))
  }

  static func normalize(_ s: String) -> String {
    var out = ""
    for scalar in s.lowercased().unicodeScalars {
      let v = scalar.value
      // Hebrew points (nikud) and cantillation
      if (0x0591...0x05C7).contains(v) { continue }
      // geresh / gershayim / quotes / apostrophes
      if v == 0x05F3 || v == 0x05F4 || v == 0x27 || v == 0x22 || v == 0x2019 || v == 0x2018 { continue }
      out.unicodeScalars.append(scalar)
    }
    // final-letter forms → regular, so "קלוד" and a trailing-ד variant compare equal
    return out.replacingOccurrences(of: "ך", with: "כ")
  }
}

extension Notification.Name {
  /// Posted when the wearer taps the glasses touchpad (the SDK pauses the stream).
  static let glassesTapPause = Notification.Name("NaveGlasses.tapPause")
  /// Posted when a second tap resumes the stream.
  static let glassesTapResume = Notification.Name("NaveGlasses.tapResume")
  /// Posted when the recorder deactivated the shared audio session (recording stopped).
  static let glassesAudioSessionReleased = Notification.Name("NaveGlasses.audioSessionReleased")
}

/// Earcons played through the app's own AVAudioSession route (the glasses),
/// not system sounds — those obey the ring/silent switch and never reach
/// Bluetooth. Short generated tones, with a light haptic on the phone.
@MainActor
enum Chime {
  private static var players: [AVAudioPlayer] = []
  private static var cache: [String: Data] = [:]

  /// Wake word caught: two quick rising notes.
  static func play() { tone("wake", notes: [(880, 0.07), (1320, 0.09)], volume: 0.5) }
  /// Question captured / sent: one clear note.
  static func playDone() { tone("done", notes: [(1046, 0.14)], volume: 0.5) }
  /// Error: a low double buzz.
  static func playError() { tone("error", notes: [(330, 0.12), (0, 0.05), (262, 0.16)], volume: 0.6) }
  /// Timer finished: three notes.
  static func playTimer() { tone("timer", notes: [(988, 0.12), (0, 0.05), (988, 0.12), (0, 0.05), (1318, 0.22)], volume: 0.7) }

  private static func tone(_ name: String, notes: [(Double, Double)], volume: Float) {
    let data = cache[name] ?? {
      let d = render(notes)
      cache[name] = d
      return d
    }()
    guard let p = try? AVAudioPlayer(data: data) else {
      DiagLog.log("chime: \(name) could not be created")
      return
    }
    p.volume = volume
    players.removeAll { !$0.isPlaying }
    players.append(p)
    let ok = p.play()
    DiagLog.log("chime: \(name) \(ok ? "playing" : "FAILED") via \(AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "?")")
    UIImpactFeedbackGenerator(style: name == "error" ? .heavy : .light).impactOccurred()
  }

  /// 16 kHz mono 16-bit sine notes with a short fade so they don't click.
  private static func render(_ notes: [(Double, Double)]) -> Data {
    let rate = 16000.0
    var pcm = Data()
    for (freq, seconds) in notes {
      let n = Int(rate * seconds)
      let fade = max(1, Int(rate * 0.008))
      for i in 0..<n {
        var amp = 0.8
        if i < fade { amp *= Double(i) / Double(fade) }
        if i > n - fade { amp *= Double(n - i) / Double(fade) }
        let v = freq == 0 ? 0.0 : sin(2 * .pi * freq * Double(i) / rate) * amp
        var sample = Int16(max(-32767, min(32767, v * 32767)))
        pcm.append(Data(bytes: &sample, count: 2))
      }
    }
    return GeminiTTS.wav(pcm: pcm, sampleRate: UInt32(rate))
  }
}
