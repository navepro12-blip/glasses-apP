//
// AssistantViewModel.swift
// Voice loop: wake word / tap → listen → (grab glasses frame) → Claude →
// speak in the ear → short follow-up window → back to wake-word listening.
//

import Foundation
import Observation
import UIKit

@Observable
@MainActor
final class AssistantViewModel {
  /// One instance for the app: the camera view re-renders on every frame and
  /// must not build a new view model (with its audio engines) each time.
  static let shared = AssistantViewModel()

  enum Phase: Equatable { case idle, listening, thinking, speaking }

  var phase: Phase = .idle
  var heardText: String = ""
  var answerText: String = ""
  var errorText: String?
  var hasKey: Bool = !AssistantSettings.shared.anthropicKey.isEmpty

  var wakeActive: Bool = false
  /// What the always-on listener hears right now (so you can see it works).
  var ambientText: String = ""
  /// Diagnostics for hands-free listening (shown when it is enabled).
  var wakeStatus: String = ""
  var wakeEnabled: Bool = AssistantSettings.shared.wakeWordEnabled
  /// True while the follow-up window (no wake word needed) is open.
  var followUpOpen: Bool = false

  @ObservationIgnored private let input = SpeechInput()
  @ObservationIgnored private let wake = WakeWordListener()
  @ObservationIgnored private var tapObservers: [NSObjectProtocol] = []
  @ObservationIgnored private var listeningFromTap = false
  @ObservationIgnored private var history: [ChatTurn] = []
  @ObservationIgnored private var frameProvider: @MainActor () -> UIImage? = { nil }
  @ObservationIgnored private let toolBox = ToolBox()
  @ObservationIgnored private var attached = false
  @ObservationIgnored private var followUpCancelled = false
  @ObservationIgnored private var errorClearTask: Task<Void, Never>?

  func attach(
    frameProvider: @escaping @MainActor () -> UIImage?,
    stillProvider: @escaping @MainActor () async -> UIImage?
  ) {
    self.frameProvider = frameProvider
    toolBox.frameProvider = frameProvider
    toolBox.stillProvider = stillProvider
    guard !attached else { return }
    attached = true

    wake.onPartial = { [weak self] text in self?.heardText = text }
    wake.onRaw = { [weak self] text in self?.ambientText = text }
    wake.onStatus = { [weak self] text in self?.wakeStatus = text }
    wake.onWake = { [weak self] in
      self?.answerText = ""
      self?.errorText = nil
      self?.heardText = "…"
      self?.wakeStatus = "שמעתי \"קלוד\" — מקשיב לשאלה"
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
      Task { await self.startListening(prompt: "כן?") }
    }

    let nc = NotificationCenter.default
    tapObservers.append(nc.addObserver(forName: .glassesTapPause, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.handleGlassesTap(resumed: false) }
    })
    tapObservers.append(nc.addObserver(forName: .glassesTapResume, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.handleGlassesTap(resumed: true) }
    })
    tapObservers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.resumeWakeListening() }
    })

    DiagLog.observeAudioSession()
    DiagLog.log("app: assistant attached, v\(AppVersion.text) \(DiagLog.sessionLine())")
    LocationContext.shared.start()
    resumeWakeListening()
  }

  /// Tap the glasses touchpad: first tap starts listening, second tap sends.
  private func handleGlassesTap(resumed: Bool) {
    guard hasKey else { return }
    if !resumed, phase == .idle {
      listeningFromTap = true
      Task { await startListening(prompt: nil) }
    } else if resumed, phase == .listening, listeningFromTap {
      listeningFromTap = false
      followUpCancelled = true
      Task { await finishAndAsk() }
    }
  }

  func setWakeWord(_ on: Bool) {
    AssistantSettings.shared.wakeWordEnabled = on
    if on { resumeWakeListening() } else { pauseWakeListening() }
  }

  private func resumeWakeListening() {
    wakeEnabled = AssistantSettings.shared.wakeWordEnabled
    guard wakeEnabled else {
      wakeStatus = ""
      wakeActive = false
      return
    }
    guard hasKey else {
      wakeStatus = "האזנה כבויה: חסר מפתח Anthropic"
      return
    }
    guard phase == .idle, !wake.isRunning else { return }
    wakeStatus = "מפעיל האזנה…"
    Task {
      do {
        try await wake.start(language: AssistantSettings.shared.listenLanguage)
        wakeActive = wake.isRunning
      } catch {
        wakeActive = false
        wakeStatus = "ההאזנה לא הופעלה: \(error.localizedDescription)"
      }
    }
  }

  private func pauseWakeListening() {
    wake.stop()
    wakeActive = false
  }

  /// Called when the settings sheet closes: keys / language / toggles may have changed.
  func refreshKeyState() {
    hasKey = !AssistantSettings.shared.anthropicKey.isEmpty
    if AssistantSettings.shared.locationEnabled { LocationContext.shared.start() } else { LocationContext.shared.stop() }
    guard phase == .idle else { return }
    pauseWakeListening()
    resumeWakeListening()
  }

  /// Tap once to start listening, tap again to send.
  func toggleTalk() {
    switch phase {
    case .idle: Task { await startListening(prompt: nil) }
    case .listening:
      followUpCancelled = true
      Task { await finishAndAsk() }
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

  private func showError(_ text: String) {
    errorText = text
    errorClearTask?.cancel()
    errorClearTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(8))
      guard !Task.isCancelled else { return }
      self?.errorText = nil
    }
  }

  /// Starts push-to-talk listening. `prompt` (e.g. "כן?") is spoken first and
  /// allowed to finish — it must not be cut off by stopping the speech queue.
  private func startListening(prompt: String?) async {
    pauseWakeListening()
    errorText = nil
    if let prompt {
      SpeechOutput.shared.enqueue(prompt)
      await SpeechOutput.shared.waitUntilIdle(maxSeconds: 4)
    } else {
      SpeechOutput.shared.stopAll()
    }
    input.onPartial = { [weak self] text in self?.heardText = text }
    do {
      heardText = ""
      phase = .listening
      try await input.start(language: AssistantSettings.shared.listenLanguage)
      Chime.play()
      if prompt != nil {
        // Hands-free: nobody will tap "send", so end on silence.
        Task { await self.finishOnSilence(maxSeconds: 10, minSpeechGap: 1.5) }
      }
    } catch {
      phase = .idle
      showError(error.localizedDescription)
      resumeWakeListening()
    }
  }

  /// Waits until the speaker pauses (or nothing is said), then sends.
  private func finishOnSilence(maxSeconds: Double, minSpeechGap: Double) async {
    let deadline = Date().addingTimeInterval(maxSeconds)
    followUpCancelled = false
    while phase == .listening, !followUpCancelled, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(200))
      let text = input.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      let gap = Date().timeIntervalSince(input.lastChange)
      if !text.isEmpty, gap > minSpeechGap { break }
      if text.isEmpty, gap > 5 { break }
    }
    guard phase == .listening, !followUpCancelled else { return }
    if input.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      // Nothing was said: close quietly (no need to wait for the recognizer).
      input.cancel()
      phase = .idle
      if !followUpOpen { showError("לא שמעתי כלום — נסה שוב.") }
      followUpOpen = false
      heardText = ""
      resumeWakeListening()
      return
    }
    await finishAndAsk()
  }

  private func finishAndAsk() async {
    let question = await input.finish()
    heardText = question
    guard !question.isEmpty else {
      phase = .idle
      if !followUpOpen { showError("לא שמעתי כלום — נסה שוב.") }
      followUpOpen = false
      resumeWakeListening()
      return
    }
    followUpOpen = false
    await ask(question)
  }

  private func ask(_ question: String) async {
    pauseWakeListening()
    heardText = question
    errorText = nil
    phase = .thinking
    let settings = AssistantSettings.shared
    let jpeg = settings.useCamera ? frameProvider().flatMap { ClaudeClient.jpeg($0) } : nil
    let client = ClaudeClient(apiKey: settings.anthropicKey, model: settings.model.rawValue, tools: toolBox)
    do {
      let answer = try await client.ask(history: history, question: question, imageJPEG: jpeg)
      answerText = answer
      history.append(ChatTurn(role: "user", text: question))
      history.append(ChatTurn(role: "assistant", text: answer))
      if history.count > 12 { history.removeFirst(history.count - 12) }
      phase = .speaking
      SpeechOutput.shared.enqueue(answer)
      await waitForSpeech()
      guard phase == .speaking else { return }  // stopped by the user
      phase = .idle
      if settings.followUpEnabled {
        await listenForFollowUp()
        return
      }
    } catch {
      phase = .idle
      showError(error.localizedDescription)
      SpeechOutput.shared.enqueue("הייתה תקלה, נסה שוב.")
    }
    resumeWakeListening()
  }

  /// A few seconds after an answer, listen for a follow-up without the wake word.
  private func listenForFollowUp() async {
    followUpOpen = true
    wakeStatus = "אפשר להמשיך לדבר בלי \"קלוד\"…"
    input.onPartial = { [weak self] text in self?.heardText = text }
    do {
      heardText = ""
      phase = .listening
      try await input.start(language: AssistantSettings.shared.listenLanguage)
    } catch {
      followUpOpen = false
      phase = .idle
      resumeWakeListening()
      return
    }
    await finishOnSilence(maxSeconds: 9, minSpeechGap: 1.4)
  }

  private func waitForSpeech() async {
    // Poll the queue lightly; speech is a few seconds at most.
    try? await Task.sleep(for: .milliseconds(300))
    let deadline = Date().addingTimeInterval(90)
    while SpeechOutput.shared.isBusy, phase == .speaking, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(200))
    }
  }
}
