//
// WakeWordListener.swift
// Hands-free: listens continuously (glasses mic over Bluetooth) for "קלוד" /
// "Claude". Whatever follows the wake word in the same breath becomes the
// question: "קלוד, מה האבן הזאת?". Saying only the wake word opens a short
// window for the question.
//

@preconcurrency import AVFoundation
import AudioToolbox
import Foundation
@preconcurrency import Speech

@MainActor
final class WakeWordListener {
  static let wakeWords = ["היי קלוד", "הי קלוד", "קלוד", "קלאוד", "קלוט", "hey claude", "claude", "cloud", "clod"]

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

  private(set) var isRunning = false
  /// Human-readable state for the on-screen diagnostics line.
  var onStatus: (@MainActor (String) -> Void)?
  private var observers: [NSObjectProtocol] = []
  private var lastBegin = Date.distantPast
  private var language: ListenLanguage = .hebrew
  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var generation = 0
  private var armed = false
  private var command = ""
  private var silenceTask: Task<Void, Never>?
  private var recycleTask: Task<Void, Never>?

  func start(language: ListenLanguage) async throws {
    guard !isRunning else { return }
    guard await SpeechInput.requestAuthorization() else { throw SpeechInput.InputError.notAuthorized }
    self.language = language
    isRunning = true
    observeAudioChanges()
    try beginRecognition()
  }

  /// Starting the glasses stream / Bluetooth route changes stop AVAudioEngine
  /// silently — restart listening whenever that happens.
  private func observeAudioChanges() {
    guard observers.isEmpty else { return }
    let nc = NotificationCenter.default
    let restart: @Sendable (Notification) -> Void = { [weak self] note in
      let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap {
        AVAudioSession.RouteChangeReason(rawValue: $0)
      }
      if reason == .categoryChange || reason == .override { return }
      Task { @MainActor in
        guard let self, self.isRunning, !self.armed,
          Date().timeIntervalSince(self.lastBegin) > 2
        else { return }
        try? await Task.sleep(for: .milliseconds(600))
        self.onStatus?("מתחבר מחדש למיקרופון…")
        try? self.beginRecognition()
      }
    }
    observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil, using: restart))
    observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil, using: restart))
    observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil, using: restart))
  }

  func stop() {
    isRunning = false
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    silenceTask?.cancel()
    recycleTask?.cancel()
    tearDown()
  }

  private func beginRecognition() throws {
    tearDown()
    guard isRunning else { return }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
      recognizer.isAvailable
    else { throw SpeechInput.InputError.unavailable }

    lastBegin = Date()
    armed = false
    command = ""
    generation += 1
    let gen = generation
    AudioRoute.activateForListening()

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    req.requiresOnDeviceRecognition = false
    request = req

    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    // While Bluetooth is switching the mic reports 0 Hz — installing a tap
    // then crashes the app. Retry shortly instead.
    guard format.sampleRate > 0, format.channelCount > 0 else {
      request = nil
      onStatus?("ממתין למיקרופון…")
      Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(800))
        guard let self, self.isRunning else { return }
        try? self.beginRecognition()
      }
      return
    }
    Self.installTap(on: input, format: format, request: req)
    engine.prepare()
    do {
      try engine.start()
    } catch {
      onStatus?("שגיאת מיקרופון: \(error.localizedDescription)")
      throw error
    }
    let route = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "?"
    onStatus?("מקשיב דרך: \(route)")

    task = Self.makeTask(recognizer: recognizer, request: req) { [weak self] text, ended in
      Task { @MainActor in
        guard let self, self.generation == gen else { return }
        if !text.isEmpty { self.handle(text) }
        if ended { self.restartSoon() }
      }
    }

    // Server-side recognition caps a request at about a minute; recycle it
    // while idle so listening never silently stops.
    recycleTask?.cancel()
    recycleTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(50))
      guard let self, !Task.isCancelled, self.isRunning, !self.armed, self.generation == gen else { return }
      try? self.beginRecognition()
    }
  }

  private func handle(_ text: String) {
    onRaw?(String(text.suffix(60)))
    // Don't wake on our own voice (answers / live chat read aloud).
    if !armed, SpeechOutput.shared.isBusy { return }
    let lower = text.lowercased()
    var after: String?
    for word in Self.wakeWords {
      if let r = lower.range(of: word, options: .backwards) {
        let tail = String(lower[r.upperBound...])
        if after == nil || tail.count < after!.count { after = tail }
      }
    }
    guard let tail = after else { return }
    if !armed { onWake?() }
    armed = true
    command = tail.trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?:–-").union(.whitespacesAndNewlines))
    onPartial?(command)

    // Finish when the speaker pauses: 1.3 s after the last change with a
    // question, or 4 s if only the wake word was said.
    silenceTask?.cancel()
    let wait: Duration = command.isEmpty ? .seconds(4) : .milliseconds(1300)
    silenceTask = Task { [weak self] in
      try? await Task.sleep(for: wait)
      guard let self, !Task.isCancelled, self.isRunning else { return }
      let heard = self.command
      self.stop()
      if heard.isEmpty { self.onWakeOnly?() } else { self.onCommand?(heard) }
    }
  }

  private func restartSoon() {
    guard isRunning, !armed else { return }
    Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(300))
      guard let self, self.isRunning else { return }
      try? self.beginRecognition()
    }
  }

  private func tearDown() {
    task?.cancel()
    task = nil
    if engine.isRunning { engine.stop() }
    engine.inputNode.removeTap(onBus: 0)
    request?.endAudio()
    request = nil
  }

  nonisolated private static func installTap(
    on node: AVAudioInputNode, format: AVAudioFormat, request: SFSpeechAudioBufferRecognitionRequest
  ) {
    nonisolated(unsafe) let req = request
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

extension Notification.Name {
  /// Posted when the wearer taps the glasses touchpad (the SDK pauses the stream).
  static let glassesTapPause = Notification.Name("NaveGlasses.tapPause")
  /// Posted when a second tap resumes the stream.
  static let glassesTapResume = Notification.Name("NaveGlasses.tapResume")
}


/// Short "I heard you" sound when the wake word is caught.
enum Chime {
  static func play() {
    AudioServicesPlaySystemSound(1113)
  }
}
