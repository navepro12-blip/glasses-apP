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

  @ObservationIgnored private let input = SpeechInput()
  @ObservationIgnored private var history: [ChatTurn] = []
  @ObservationIgnored private var frameProvider: @MainActor () -> UIImage? = { nil }

  func attach(frameProvider: @escaping @MainActor () -> UIImage?) {
    self.frameProvider = frameProvider
  }

  func refreshKeyState() {
    hasKey = !AssistantSettings.shared.anthropicKey.isEmpty
  }

  /// Tap once to start listening, tap again to send.
  func toggleTalk() {
    switch phase {
    case .idle: Task { await startListening() }
    case .listening: Task { await finishAndAsk() }
    case .speaking:
      SpeechOutput.shared.stopAll()
      phase = .idle
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
    }
  }

  private func finishAndAsk() async {
    let question = await input.finish()
    heardText = question
    guard !question.isEmpty else {
      phase = .idle
      errorText = "לא שמעתי כלום — נסה שוב."
      return
    }
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
  }

  private func waitForSpeech() async {
    // Poll the queue lightly; speech is a few seconds at most.
    try? await Task.sleep(for: .milliseconds(300))
    while SpeechOutput.shared.isBusy, phase == .speaking {
      try? await Task.sleep(for: .milliseconds(200))
    }
  }
}
