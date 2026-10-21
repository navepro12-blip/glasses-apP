//
// SpeechInput.swift
// Push-to-talk speech recognition (Apple Speech, Hebrew or English) from the
// current input route — the glasses mic when they're connected over Bluetooth.
//
// A fresh AVAudioEngine is built for every start(): reusing one across
// Bluetooth route changes leaves it with a stale format and installTap/start
// then raise a fatal Objective-C exception.
//

@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

@MainActor
final class SpeechInput {
  enum InputError: LocalizedError {
    case notAuthorized, unavailable
    var errorDescription: String? {
      switch self {
      case .notAuthorized: return "צריך לאשר מיקרופון וזיהוי דיבור בהגדרות של האייפון."
      case .unavailable: return "זיהוי הדיבור לא זמין כרגע לשפה הזאת."
      }
    }
  }

  private var engine: AVAudioEngine?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var generation = 0
  private(set) var transcript: String = ""
  /// Set whenever the transcript changes (used by the follow-up window).
  private(set) var lastChange = Date.distantPast
  private(set) var isListening = false
  var onPartial: (@MainActor (String) -> Void)?

  nonisolated static func requestAuthorization() async -> Bool {
    let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
    }
    let mic = await AVAudioApplication.requestRecordPermission()
    return speech && mic
  }

  func start(language: ListenLanguage) async throws {
    // Any earlier session is torn down first; a generation stamp makes sure an
    // overlapping start (e.g. two quick taps) can't install two taps.
    stopEngine()
    generation += 1
    let gen = generation
    guard await Self.requestAuthorization() else { throw InputError.notAuthorized }
    guard gen == generation else { return }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
      recognizer.isAvailable
    else { throw InputError.unavailable }

    transcript = ""
    lastChange = Date()
    AudioRoute.activateForListening(preferPhoneMic: AssistantSettings.shared.micSource == .phone)

    let newEngine = AVAudioEngine()
    let input = newEngine.inputNode
    guard let format = await AudioRoute.validInputFormat(input) else { throw InputError.unavailable }
    guard gen == generation else { return }
    stopEngine()

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    req.requiresOnDeviceRecognition = false
    req.taskHint = .dictation
    request = req
    engine = newEngine
    Self.installTap(on: input, format: format, request: req)
    newEngine.prepare()
    do {
      try newEngine.start()
    } catch {
      stopEngine()
      throw error
    }
    isListening = true
    DiagLog.log("ptt: engine started fmt=\(Int(format.sampleRate))Hz \(DiagLog.sessionLine())")

    task = Self.makeTask(recognizer: recognizer, request: req) { [weak self] text, isFinal in
      Task { @MainActor in
        guard let self, self.generation == gen else { return }
        if self.transcript != text {
          self.transcript = text
          self.lastChange = Date()
        }
        self.onPartial?(text)
        _ = isFinal
      }
    }
  }

  /// Stops listening and returns the final transcript (waits briefly for the
  /// recognizer to settle after the audio ends).
  func finish() async -> String {
    guard isListening else { return transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
    isListening = false
    request?.endAudio()
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      if engine.isRunning { engine.stop() }
    }
    engine = nil
    let gen = generation
    try? await Task.sleep(for: .milliseconds(700))
    if gen == generation {
      task?.finish()
      task = nil
      request = nil
    }
    return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func cancel() {
    generation += 1
    task?.cancel()
    task = nil
    stopEngine()
  }

  private func stopEngine() {
    isListening = false
    if let engine {
      engine.inputNode.removeTap(onBus: 0)
      if engine.isRunning { engine.stop() }
    }
    engine = nil
    request?.endAudio()
    request = nil
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
    onResult: @escaping @Sendable (String, Bool) -> Void
  ) -> SFSpeechRecognitionTask {
    recognizer.recognitionTask(with: request) { result, error in
      if let result {
        onResult(result.bestTranscription.formattedString, result.isFinal)
      } else if let error {
        let ns = error as NSError
        DiagLog.log("ptt: task error \(ns.domain)#\(ns.code) \(ns.localizedDescription)")
      }
    }
  }
}
