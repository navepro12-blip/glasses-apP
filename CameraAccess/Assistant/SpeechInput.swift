//
// SpeechInput.swift
// Push-to-talk speech recognition (Apple Speech, Hebrew or English) from the
// current input route — the glasses mic when they're connected over Bluetooth.
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

  private let engine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private(set) var transcript: String = ""
  var onPartial: (@MainActor (String) -> Void)?

  nonisolated static func requestAuthorization() async -> Bool {
    let speech = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
    }
    let mic = await AVAudioApplication.requestRecordPermission()
    return speech && mic
  }

  func start(language: ListenLanguage) async throws {
    guard await Self.requestAuthorization() else { throw InputError.notAuthorized }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language.rawValue)),
      recognizer.isAvailable
    else { throw InputError.unavailable }

    stopEngine()
    transcript = ""
    AudioRoute.activateForListening()

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = false }
    request = req

    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    Self.installTap(on: input, format: format, request: req)
    engine.prepare()
    try engine.start()

    task = Self.makeTask(recognizer: recognizer, request: req) { [weak self] text, isFinal in
      Task { @MainActor in
        guard let self else { return }
        self.transcript = text
        self.onPartial?(text)
        _ = isFinal
      }
    }
  }

  /// Stops listening and returns the final transcript (waits briefly for the
  /// recognizer to settle after the audio ends).
  func finish() async -> String {
    request?.endAudio()
    engine.stop()
    engine.inputNode.removeTap(onBus: 0)
    try? await Task.sleep(for: .milliseconds(700))
    task?.finish()
    task = nil
    request = nil
    return transcript.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  func cancel() {
    task?.cancel()
    task = nil
    stopEngine()
  }

  private func stopEngine() {
    if engine.isRunning { engine.stop() }
    engine.inputNode.removeTap(onBus: 0)
    request?.endAudio()
    request = nil
  }

  // Built outside the main actor: the tap and result blocks run on audio /
  // speech threads, and Swift 6 would otherwise trap on the isolation check.
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
    recognizer.recognitionTask(with: request) { result, _ in
      if let result {
        onResult(result.bestTranscription.formattedString, result.isFinal)
      }
    }
  }
}
