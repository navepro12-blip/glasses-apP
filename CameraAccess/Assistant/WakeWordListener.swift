//
// WakeWordListener.swift
// Hands-free: listens continuously (glasses mic over Bluetooth) for "קלוד" /
// "Claude". Whatever follows the wake word in the same breath becomes the
// question: "קלוד, מה האבן הזאת?". Saying only the wake word opens a short
// window for the question.
//
// Robustness notes (these were the crash sources):
// - A fresh AVAudioEngine is created for every listening attempt. Reusing one
//   engine across Bluetooth route changes (A2DP ↔ HFP, glasses on/off) leaves
//   it with a stale hardware format, and installTap/start then raise an
//   Objective-C exception that kills the app.
// - The tap is always removed before a new one is installed (installing twice
//   on the same bus is also a fatal exception).
// - Every restart path goes through one serialised `beginRecognition()` with a
//   generation counter, so late callbacks from an old task are ignored.
//

@preconcurrency import AVFoundation
import AudioToolbox
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
  private var consecutiveFailures = 0

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
    consecutiveFailures = 0
    try beginRecognition()
  }

  func stop() {
    isRunning = false
    AudioRoute.assistantListening = false
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    silenceTask?.cancel()
    recycleTask?.cancel()
    restartTask?.cancel()
    silenceTask = nil
    recycleTask = nil
    restartTask = nil
    tearDown()
  }

  // MARK: - Audio route / engine changes

  /// Starting the glasses stream, Bluetooth route changes and the end of a
  /// recording all stop AVAudioEngine silently — restart listening then.
  private func observeAudioChanges() {
    guard observers.isEmpty else { return }
    let nc = NotificationCenter.default
    let restart: @Sendable (Notification) -> Void = { [weak self] _ in
      Task { @MainActor in self?.scheduleRestart(after: .milliseconds(700), reason: "מתחבר מחדש למיקרופון…") }
    }
    // object: nil — the engine instance changes on every restart.
    observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil, using: restart))
    observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil, using: restart))
    observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil, using: restart))
    observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil, using: restart))
    observers.append(nc.addObserver(forName: .glassesAudioSessionReleased, object: nil, queue: nil, using: restart))
  }

  /// Coalesces restart requests: many notifications arrive in a burst when
  /// Bluetooth switches profiles, and only the last one matters.
  private func scheduleRestart(after delay: Duration, reason: String?) {
    guard isRunning, !armed else { return }
    restartTask?.cancel()
    restartTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard let self, !Task.isCancelled, self.isRunning, !self.armed else { return }
      if let reason { self.onStatus?(reason) }
      self.beginRecognitionSafely()
    }
  }

  private func beginRecognitionSafely() {
    do {
      try beginRecognition()
      consecutiveFailures = 0
    } catch {
      consecutiveFailures += 1
      onStatus?("המיקרופון לא זמין (\(error.localizedDescription)) — מנסה שוב")
      // Back off so a dead route doesn't turn into a tight restart loop.
      let seconds = min(10, 1 << min(consecutiveFailures, 3))
      scheduleRestart(after: .seconds(seconds), reason: nil)
    }
  }

  // MARK: - Recognition

  private func beginRecognition() throws {
    tearDown()
    guard isRunning else { return }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
      recognizer.isAvailable
    else { throw SpeechInput.InputError.unavailable }

    armed = false
    command = ""
    generation += 1
    let gen = generation
    AudioRoute.activateForListening()

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    req.requiresOnDeviceRecognition = false
    req.taskHint = .dictation
    req.contextualStrings = WakeWord.contextualStrings
    request = req

    let newEngine = AVAudioEngine()
    let input = newEngine.inputNode
    let format = input.outputFormat(forBus: 0)
    // While Bluetooth is switching the mic reports 0 Hz — installing a tap
    // then crashes the app. Retry shortly instead.
    guard format.sampleRate > 0, format.channelCount > 0 else {
      request = nil
      onStatus?("ממתין למיקרופון…")
      scheduleRestart(after: .milliseconds(900), reason: nil)
      return
    }
    engine = newEngine
    Self.installTap(on: input, format: format, request: req)
    newEngine.prepare()
    do {
      try newEngine.start()
    } catch {
      newEngine.inputNode.removeTap(onBus: 0)
      engine = nil
      request = nil
      throw error
    }
    let route = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "?"
    onStatus?("👂 מקשיב דרך: \(route)")

    task = Self.makeTask(recognizer: recognizer, request: req) { [weak self] text, ended in
      Task { @MainActor in
        guard let self, self.generation == gen, self.isRunning else { return }
        if !text.isEmpty { self.handle(text) }
        if ended { self.scheduleRestart(after: .milliseconds(250), reason: nil) }
      }
    }

    // Server-side recognition caps a request at about a minute; recycle it
    // while idle so listening never silently stops.
    recycleTask?.cancel()
    recycleTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(45))
      guard let self, !Task.isCancelled, self.isRunning, !self.armed, self.generation == gen else { return }
      self.beginRecognitionSafely()
    }
  }

  private func handle(_ text: String) {
    onRaw?(String(text.suffix(60)))
    // Don't wake on our own voice (answers / live chat read aloud).
    if !armed, SpeechOutput.shared.isBusy { return }
    guard let tail = WakeWord.commandAfterWakeWord(in: text) else { return }
    if !armed { onWake?() }
    armed = true
    command = tail
    onPartial?(command)

    // Finish when the speaker pauses: 1.4 s after the last change with a
    // question, or 3 s if only the wake word was said.
    silenceTask?.cancel()
    let wait: Duration = command.isEmpty ? .seconds(3) : .milliseconds(1400)
    silenceTask = Task { [weak self] in
      try? await Task.sleep(for: wait)
      guard let self, !Task.isCancelled, self.isRunning, self.armed else { return }
      let heard = self.command
      self.stop()
      if heard.isEmpty { self.onWakeOnly?() } else { self.onCommand?(heard) }
    }
  }

  private func tearDown() {
    task?.cancel()
    task = nil
    request?.endAudio()
    request = nil
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      if engine.isRunning { engine.stop() }
    }
    engine = nil
  }

  // Built outside the main actor: the tap and result blocks run on audio /
  // speech threads, and Swift 6 would otherwise trap on the isolation check.
  nonisolated private static func installTap(
    on node: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest
  ) {
    nonisolated(unsafe) let req = request
    node.removeTap(onBus: 0)
    node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      req.append(buffer)
    }
  }

  nonisolated private static func makeTask(
    recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
    onResult: @escaping @Sendable (String, Bool) -> Void
  ) -> SFSpeechRecognitionTask {
    recognizer.recognitionTask(with: request) { result, error in
      if let result {
        onResult(result.bestTranscription.formattedString, result.isFinal)
      } else if error != nil {
        onResult("", true)
      }
    }
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

  /// Returns the text after the (last) wake word, or nil if it wasn't said.
  /// The command is trimmed of punctuation; an empty string means "name only".
  static func commandAfterWakeWord(in text: String) -> String? {
    let tokens = text.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == "." || $0 == "!" || $0 == "?" })
      .map(String.init)
    guard let idx = tokens.lastIndex(where: isWakeToken) else { return nil }
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

/// Short "I heard you" sound when the wake word is caught.
enum Chime {
  static func play() {
    AudioServicesPlaySystemSound(1113)
  }
  static func playDone() {
    AudioServicesPlaySystemSound(1114)
  }
  static func playTimer() {
    AudioServicesPlaySystemSound(1005)
  }
}
