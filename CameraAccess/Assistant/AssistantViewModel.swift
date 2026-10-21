//
// AssistantViewModel.swift
// Push-to-talk loop: listen → (grab glasses frame) → Claude → speak in the ear.
//

import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class AssistantViewModel {
  enum Phase: Equatable { case idle, listening, thinking, speaking }

  var phase: Phase = .idle
  var heardText: String = ""
  var answerText: String = ""
  var errorText: String?
  var hasKey: Bool = !AssistantSettings.shared.anthropicKey.isEmpty

  var wakeActive: Bool = false
  /// What the always-on listener hears right now (so you can see it works).
  var ambientText: String = ""

  @ObservationIgnored private let input = SpeechInput()
  @ObservationIgnored private let wake = WakeWordListener()
  @ObservationIgnored private var tapObservers: [NSObjectProtocol] = []
  @ObservationIgnored private var listeningFromTap = false
  @ObservationIgnored private var history: [ChatTurn] = []
  @ObservationIgnored private var frameProvider: @MainActor () -> UIImage? = { nil }

  func attach(frameProvider: @escaping @MainActor () -> UIImage?) {
    self.frameProvider = frameProvider
    wake.onPartial = { [weak self] text in self?.heardText = text }
    wake.onRaw = { [weak self] text in self?.ambientText = text }
    wake.onWake = { [weak self] in
      self?.answerText = ""
      self?.heardText = "…"
      Chime.play()
    }
    wake.onCommand = { [weak self] text in
      guard let self else { return }
      self.wakeActive = false
      Task { await self.ask(text) }
    }
    wake.onWakeOnly = { [weak self] in
      guard let self else { return }
      self.wakeActive = false
      SpeechOutput.shared.enqueue("כן?")
      Task {
        try? await Task.sleep(for: .milliseconds(700))
        await self.startListening()
      }
    }
    if tapObservers.isEmpty {
      let nc = NotificationCenter.default
      tapObservers.append(nc.addObserver(forName: .glassesTapPause, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.handleGlassesTap(resumed: false) }
      })
      tapObservers.append(nc.addObserver(forName: .glassesTapResume, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.handleGlassesTap(resumed: true) }
      })
    }
    resumeWakeListening()
  }

  /// Tap the glasses touchpad: first tap starts listening, second tap sends.
  private func handleGlassesTap(resumed: Bool) {
    guard hasKey else { return }
    if !resumed, phase == .idle {
      listeningFromTap = true
      Task { await startListening() }
    } else if resumed, phase == .listening, listeningFromTap {
      listeningFromTap = false
      Task { await finishAndAsk() }
    }
  }

  func setWakeWord(_ on: Bool) {
    AssistantSettings.shared.wakeWordEnabled = on
    if on { resumeWakeListening() } else { pauseWakeListening() }
  }

  private func resumeWakeListening() {
    guard AssistantSettings.shared.wakeWordEnabled, hasKey, phase == .idle, !wake.isRunning else { return }
    Task {
      do {
        try await wake.start(language: AssistantSettings.shared.listenLanguage)
        wakeActive = true
      } catch {
        wakeActive = false
        errorText = error.localizedDescription
      }
    }
  }

  private func pauseWakeListening() {
    wake.stop()
    wakeActive = false
  }

  func refreshKeyState() {
    hasKey = !AssistantSettings.shared.anthropicKey.isEmpty
    pauseWakeListening()
    resumeWakeListening()
  }

  /// Tap once to start listening, tap again to send.
  func toggleTalk() {
    switch phase {
    case .idle: Task { await startListening() }
    case .listening: Task { await finishAndAsk() }
    case .speaking:
      SpeechOutput.shared.stopAll()
      phase = .idle
      resumeWakeListening()
    case .thinking: break
    }
  }

  func resetConversation() {
    history.removeAll()
    heardText = ""
    answerText = ""
    errorText = nil
  }

  private func startListening() async {
    pauseWakeListening()
    errorText = nil
    SpeechOutput.shared.stopAll()
    input.onPartial = { [weak self] text in self?.heardText = text }
    do {
      heardText = ""
      phase = .listening
      try await input.start(language: AssistantSettings.shared.listenLanguage)
    } catch {
      phase = .idle
      errorText = error.localizedDescription
      resumeWakeListening()
    }
  }

  private func finishAndAsk() async {
    let question = await input.finish()
    heardText = question
    guard !question.isEmpty else {
      phase = .idle
      errorText = "לא שמעתי כלום — נסה שוב."
      resumeWakeListening()
      return
    }
    await ask(question)
  }

  private func ask(_ question: String) async {
    pauseWakeListening()
    heardText = question
    phase = .thinking
    let settings = AssistantSettings.shared
    let jpeg = settings.useCamera ? frameProvider().flatMap { ClaudeClient.jpeg($0) } : nil
    let client = ClaudeClient(apiKey: settings.anthropicKey, model: settings.model.rawValue)
    do {
      let answer = try await client.ask(history: history, question: question, imageJPEG: jpeg)
      answerText = answer
      history.append(ChatTurn(role: "user", text: question))
      history.append(ChatTurn(role: "assistant", text: answer))
      if history.count > 12 { history.removeFirst(history.count - 12) }
      phase = .speaking
      SpeechOutput.shared.enqueue(answer)
      await waitForSpeech()
      if phase == .speaking { phase = .idle }
    } catch {
      phase = .idle
      errorText = error.localizedDescription
      SpeechOutput.shared.enqueue("הייתה תקלה, נסה שוב.")
    }
    resumeWakeListening()
  }

  private func waitForSpeech() async {
    // Poll the queue lightly; speech is a few seconds at most.
    try? await Task.sleep(for: .milliseconds(300))
    while SpeechOutput.shared.isBusy, phase == .speaking {
      try? await Task.sleep(for: .milliseconds(200))
    }
  }
}
