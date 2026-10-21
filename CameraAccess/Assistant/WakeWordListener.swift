//
// WakeWordListener.swift
// Hands-free: listens continuously (glasses mic over Bluetooth) for "קלוד" /
// "Claude". Whatever follows the wake word in the same breath becomes the
// question: "קלוד, מה האבן הזאת?". Saying only the wake word opens a short
// window for the question.
//

@preconcurrency import AVFoundation
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

  private(set) var isRunning = false
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
    try beginRecognition()
  }

  func stop() {
    isRunning = false
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

    armed = false
    command = ""
    generation += 1
    let gen = generation
    AudioRoute.activateForListening()

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
    request = req

    let input = engine.inputNode
    Self.installTap(on: input, format: input.outputFormat(forBus: 0), request: req)
    engine.prepare()
    try engine.start()

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
    let lower = text.lowercased()
    var after: String?
    for word in Self.wakeWords {
      if let r = lower.range(of: word, options: .backwards) {
        let tail = String(lower[r.upperBound...])
        if after == nil || tail.count < after!.count { after = tail }
      }
    }
    guard let tail = after else { return }
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
