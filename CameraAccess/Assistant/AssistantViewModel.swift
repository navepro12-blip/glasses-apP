//
// AssistantViewModel.swift
// The "Hey Meta"-style loop, with Claude: wake word → instant tone → speak →
// thinking cue → streamed answer → short follow-up window → back to passive
// listening. Interruptible at any time ("קלוד …" or a stop phrase).
//

import AVFoundation
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
  /// The glasses device session is started: only then does the assistant listen.
  var sessionReady: Bool = false

  @ObservationIgnored private let input = SpeechInput()
  @ObservationIgnored private let wake = WakeWordListener()
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var listeningFromTap = false
  @ObservationIgnored private var history: [ChatTurn] = []
  @ObservationIgnored private var frameProvider: @MainActor () -> UIImage? = { nil }
  @ObservationIgnored private let toolBox = ToolBox()
  @ObservationIgnored private var attached = false
  @ObservationIgnored private var followUpCancelled = false
  @ObservationIgnored private var errorClearTask: Task<Void, Never>?
  @ObservationIgnored private var watchdogTask: Task<Void, Never>?
  @ObservationIgnored private var phaseSince = Date()
  @ObservationIgnored private var askTask: Task<Void, Never>?
  @ObservationIgnored private var fillerTask: Task<Void, Never>?
  @ObservationIgnored private var inBackground = false
  /// Streaming answer: text not yet cut into a sentence for TTS.
  @ObservationIgnored private var pendingSpeech = ""
  @ObservationIgnored private var sentencesSpoken = 0

  // MARK: - Setup

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
      guard let self else { return }
      if self.phase != .idle {
        // Barge-in: a new "קלוד …" while thinking / talking.
        self.cancelCurrent(reason: "wake word while \(self.phase)", chime: false, restartWake: false)
      }
      self.answerText = ""
      self.errorText = nil
      self.heardText = "…"
      self.wakeStatus = "שמעתי \"קלוד\" — מקשיב לשאלה"
      Chime.play()
    }
    wake.onCommand = { [weak self] text in
      guard let self else { return }
      self.wakeActive = false
      self.askTask = Task { await self.ask(text) }
    }
    wake.onWakeOnly = { [weak self] in
      guard let self else { return }
      self.wakeActive = false
      Task { await self.startListening(prompt: "כן?") }
    }
    wake.onStop = { [weak self] in
      self?.cancelCurrent(reason: "stop phrase", chime: true, restartWake: true)
    }

    let nc = NotificationCenter.default
    observers.append(nc.addObserver(forName: .glassesTapPause, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.handleGlassesTap(resumed: false) }
    })
    observers.append(nc.addObserver(forName: .glassesTapResume, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.handleGlassesTap(resumed: true) }
    })
    observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.inBackground = false
        DiagLog.log("app: active")
        self.resumeWakeListening()
      }
    })
    observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.inBackground = true
        if AssistantSettings.shared.backgroundListening, self.sessionReady {
          DiagLog.log("app: background — keeps listening (glasses connected, setting on)")
        } else {
          self.releaseMic(reason: "app to background")
        }
      }
    })

    DiagLog.observeAudioSession()
    DiagLog.log("app: assistant attached, v\(AppVersion.text) \(DiagLog.sessionLine())")
    LocationContext.shared.start()
    startWatchdog()
    resumeWakeListening()
  }

  /// Called by the camera screen whenever the device session state changes.
  /// Listening is tied to a started session: that is when the glasses' audio
  /// link is ours; before that the Meta AI app owns it and results are flaky.
  func setSessionReady(_ ready: Bool) {
    guard ready != sessionReady else { return }
    sessionReady = ready
    DiagLog.log("app: session ready=\(ready)")
    if ready {
      resumeWakeListening()
    } else {
      cancelCurrent(reason: "session ended", chime: false, restartWake: false)
      releaseMic(reason: "session ended")
      wakeStatus = "התחל סשן כדי לדבר עם Claude"
    }
  }

  /// Stops every engine and recogniser and deactivates the audio session so
  /// the orange microphone indicator goes away.
  private func releaseMic(reason: String) {
    input.cancel()
    wake.releaseEngine(reason: reason)
    wakeActive = false
    if phase == .listening { setPhase(.idle) }
    if phase == .idle { AudioRoute.deactivate(reason: reason) }
  }

  // MARK: - Watchdog

  /// If anything leaves the pipeline stuck outside idle, reset it.
  private func startWatchdog() {
    watchdogTask?.cancel()
    watchdogTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        guard let self else { return }
        let stuck = Date().timeIntervalSince(self.phaseSince)
        if self.phase != .idle, stuck > 45 {
          DiagLog.log("watchdog: phase \(self.phase) for \(Int(stuck)) s — resetting")
          self.cancelCurrent(reason: "watchdog", chime: false, restartWake: true)
          self.showError("האפליקציה נתקעה ואופסה — נסה שוב")
        } else if self.phase == .idle, self.canListen, !self.wake.isRunning, stuck > 10 {
          DiagLog.log("watchdog: idle but not listening — restarting the wake listener")
          self.resumeWakeListening()
        }
      }
    }
  }

  private var canListen: Bool {
    sessionReady && wakeEnabled && hasKey && (!inBackground || AssistantSettings.shared.backgroundListening)
  }

  private func setPhase(_ p: Phase) {
    guard p != phase else { return }
    DiagLog.log("state: \(phase) → \(p)")
    phaseSince = Date()
    phase = p
    wake.conversationActive = (p == .thinking || p == .speaking)
  }

  // MARK: - Wake listening

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
    wakeEnabled = on
    if on {
      resumeWakeListening()
    } else {
      cancelCurrent(reason: "wake toggle off", chime: false, restartWake: false)
      releaseMic(reason: "wake toggle off")
    }
  }

  /// Starts (or keeps) the wake listener. During thinking/speaking it runs in
  /// barge-in mode (stop phrases + new "קלוד" questions, echo filtered).
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
    guard sessionReady else {
      wakeStatus = "התחל סשן כדי לדבר עם Claude"
      wakeActive = false
      return
    }
    guard !inBackground || AssistantSettings.shared.backgroundListening else { return }
    guard phase != .listening, !wake.isRunning else {
      if phase == .listening { DiagLog.log("state: wake not started — push-to-talk window is open") }
      return
    }
    wake.conversationActive = (phase == .thinking || phase == .speaking)
    if phase == .idle { wakeStatus = "מפעיל האזנה…" }
    DiagLog.log("state: → wake listening (barge-in=\(wake.conversationActive))")
    Task {
      do {
        try await wake.start(language: AssistantSettings.shared.listenLanguage)
        wakeActive = wake.isRunning && phase == .idle
      } catch {
        wakeActive = false
        wakeStatus = "ההאזנה לא הופעלה: \(error.localizedDescription)"
      }
    }
  }

  /// Hands the mic to push-to-talk / follow-up (keeps the Bluetooth route up).
  private func pauseWakeListening() {
    wake.stop(keepRoute: true, reason: "handing mic to push-to-talk")
    wakeActive = false
  }

  /// Called when the settings sheet closes: keys / language / toggles may have changed.
  func refreshKeyState() {
    hasKey = !AssistantSettings.shared.anthropicKey.isEmpty
    if AssistantSettings.shared.locationEnabled { LocationContext.shared.start() } else { LocationContext.shared.stop() }
    wakeEnabled = AssistantSettings.shared.wakeWordEnabled
    guard phase == .idle else { return }
    if wakeEnabled {
      wake.stop(keepRoute: true, reason: "settings changed")
    } else {
      releaseMic(reason: "wake disabled in settings")
    }
    resumeWakeListening()
  }

  // MARK: - User controls

  /// Tap once to start listening, tap again to send.
  func toggleTalk() {
    switch phase {
    case .idle: Task { await startListening(prompt: nil) }
    case .listening:
      followUpCancelled = true
      Task { await finishAndAsk() }
    case .speaking, .thinking:
      cancelCurrent(reason: "user tapped stop", chime: true, restartWake: true)
    }
  }

  func resetConversation() {
    history.removeAll()
    heardText = ""
    answerText = ""
    errorText = nil
  }

  /// Aborts whatever is going on (request, speech, windows) and returns to
  /// passive wake listening.
  private func cancelCurrent(reason: String, chime: Bool, restartWake: Bool) {
    DiagLog.log("state: cancel (\(reason)) from \(phase)")
    askTask?.cancel()
    askTask = nil
    fillerTask?.cancel()
    fillerTask = nil
    Chime.stopThinking()
    SpeechOutput.shared.stopAll()
    followUpCancelled = true
    followUpOpen = false
    input.cancel()
    pendingSpeech = ""
    if chime { Chime.playClose() }
    setPhase(.idle)
    if restartWake {
      // Fresh recognition request so the old transcript is gone.
      wake.stop(keepRoute: true, reason: "cancel → fresh request")
      resumeWakeListening()
    }
  }

  private func showError(_ text: String) {
    DiagLog.log("error shown: \(text)")
    Chime.playError()
    errorText = text
    errorClearTask?.cancel()
    errorClearTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(8))
      guard !Task.isCancelled else { return }
      self?.errorText = nil
    }
  }

  // MARK: - Push-to-talk / follow-up windows

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
      setPhase(.listening)
      try await input.start(language: AssistantSettings.shared.listenLanguage)
      Chime.play()
      DiagLog.log("state: push-to-talk window open (hands-free=\(prompt != nil))")
      if prompt != nil {
        // Hands-free: nobody will tap "send", so end on silence.
        Task { await self.finishOnSilence(maxSeconds: 12, minSpeechGap: 1.0) }
      }
    } catch {
      setPhase(.idle)
      showError(error.localizedDescription)
      resumeWakeListening()
    }
  }

  /// Waits until the speaker pauses (or nothing is said), then sends. Stop
  /// phrases cancel; silence for `idleTimeoutSeconds` closes the window.
  private func finishOnSilence(maxSeconds: Double, minSpeechGap: Double) async {
    let deadline = Date().addingTimeInterval(maxSeconds)
    let idleLimit = AssistantSettings.shared.idleTimeoutSeconds
    followUpCancelled = false
    var text = ""
    while phase == .listening, !followUpCancelled, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(150))
      text = input.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      let gap = Date().timeIntervalSince(input.lastChange)
      if WakeWord.isStopPhrase(text), gap > 0.6 {
        DiagLog.log("state: stop phrase in window '\(text)'")
        cancelCurrent(reason: "stop phrase in window", chime: true, restartWake: true)
        return
      }
      if !text.isEmpty, gap > minSpeechGap { break }
      if text.isEmpty, gap > idleLimit { break }
    }
    guard phase == .listening, !followUpCancelled else { return }
    if text.isEmpty {
      // Nothing was said: close quietly and go back to passive listening.
      DiagLog.log("state: window closed — no speech for \(Int(idleLimit)) s (follow-up=\(followUpOpen))")
      input.cancel()
      followUpOpen = false
      heardText = ""
      Chime.playClose()
      setPhase(.idle)
      resumeWakeListening()
      return
    }
    await finishAndAsk()
  }

  private func finishAndAsk() async {
    var question = await input.finish()
    // "קלוד, …" said inside the follow-up / push-to-talk window: drop the name.
    if let tail = WakeWord.commandAfterWakeWord(in: question), !tail.isEmpty { question = tail }
    DiagLog.log("state: captured (follow-up=\(followUpOpen)) '\(question.prefix(40))'")
    heardText = question
    guard !question.isEmpty, !WakeWord.isStopPhrase(question) else {
      setPhase(.idle)
      if !followUpOpen, question.isEmpty { showError("לא שמעתי כלום — נסה שוב.") } else { Chime.playClose() }
      followUpOpen = false
      resumeWakeListening()
      return
    }
    followUpOpen = false
    askTask = Task { await ask(question) }
  }

  // MARK: - Ask Claude

  private func ask(_ question: String) async {
    let endOfSpeech = Date()
    heardText = question
    errorText = nil
    setPhase(.thinking)
    // Instant acknowledgement, then a soft pulse while Claude works.
    Chime.playDone()
    Chime.startThinking()
    SpeechOutput.shared.beginTrace(at: endOfSpeech)
    DiagLog.log("latency: question captured '\(question.prefix(40))' input=\(AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "?")")
    // Barge-in listener (stop phrases / new "קלוד") while we work.
    resumeWakeListening()

    let settings = AssistantSettings.shared
    let jpeg = settings.useCamera ? frameProvider().flatMap { ClaudeClient.jpeg($0) } : nil
    var client = ClaudeClient(apiKey: settings.anthropicKey, model: settings.model.rawValue, tools: toolBox)
    pendingSpeech = ""
    sentencesSpoken = 0
    answerText = ""
    let progress = AskProgress()
    // Never sit on "חושב…" forever: give up after 30 s without a first token.
    let watchdog = Task { [weak self] in
      try? await Task.sleep(for: .seconds(30))
      guard let self, !Task.isCancelled, self.phase == .thinking, !progress.gotToken else { return }
      DiagLog.log("claude: no answer after 30 s — giving up")
      self.cancelCurrent(reason: "timeout", chime: false, restartWake: true)
      self.showError("לקח יותר מדי זמן — נסה שוב")
      SpeechOutput.shared.enqueue("לקח לי יותר מדי זמן, נסה שוב.")
    }
    defer { watchdog.cancel() }
    client.onTool = { [weak self] name in
      guard let self, !progress.gotToken, !progress.fillerSaid else { return }
      // A tool (web search, calendar…) is running: after 3 s say we're on it.
      self.fillerTask?.cancel()
      self.fillerTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(3))
        guard let self, !Task.isCancelled, self.phase == .thinking, !progress.gotToken, !progress.fillerSaid else { return }
        progress.fillerSaid = true
        DiagLog.log("state: filler after slow tool \(name)")
        SpeechOutput.shared.enqueue("רגע, בודקת…")
        await SpeechOutput.shared.waitUntilIdle(maxSeconds: 6)
        if self.phase == .thinking, !progress.gotToken { Chime.startThinking() }
      }
    }
    do {
      let answer = try await client.ask(history: history, question: question, imageJPEG: jpeg) { [weak self] delta in
        guard let self, !Task.isCancelled else { return }
        if !progress.gotToken {
          progress.gotToken = true
          DiagLog.log("latency: first token \(Int(Date().timeIntervalSince(endOfSpeech) * 1000)) ms after end of speech")
          self.fillerTask?.cancel()
          Chime.stopThinking()
          self.setPhase(.speaking)
        }
        self.answerText += delta
        self.pendingSpeech += delta
        self.flushSentences(final: false)
      }
      guard !Task.isCancelled else { return }
      fillerTask?.cancel()
      Chime.stopThinking()
      answerText = answer
      flushSentences(final: true)
      if sentencesSpoken == 0 { SpeechOutput.shared.enqueue(answer) }
      history.append(ChatTurn(role: "user", text: question))
      history.append(ChatTurn(role: "assistant", text: answer))
      if history.count > 12 { history.removeFirst(history.count - 12) }
      setPhase(.speaking)
      await waitForSpeech()
      guard !Task.isCancelled, phase == .speaking else { return }  // cancelled / barged in
      DiagLog.log("latency: answer fully spoken \(Int(Date().timeIntervalSince(endOfSpeech) * 1000)) ms after end of speech")
      setPhase(.idle)
      if settings.followUpEnabled {
        await listenForFollowUp()
        return
      }
    } catch is CancellationError {
      DiagLog.log("claude: request cancelled")
      return
    } catch {
      guard !Task.isCancelled else { return }
      DiagLog.log("claude: failed — \(error)")
      fillerTask?.cancel()
      Chime.stopThinking()
      SpeechOutput.shared.stopAll()
      setPhase(.idle)
      showError(error.localizedDescription)
      SpeechOutput.shared.enqueue("לא הצלחתי, נסה שוב.")
    }
    resumeWakeListening()
  }

  /// Cuts `pendingSpeech` at sentence boundaries and sends complete sentences
  /// to TTS while the rest of the answer is still streaming.
  private func flushSentences(final: Bool) {
    while true {
      guard let cut = Self.sentenceBoundary(in: pendingSpeech, minChars: sentencesSpoken == 0 ? 25 : 40) else { break }
      let sentence = String(pendingSpeech[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
      pendingSpeech = String(pendingSpeech[cut...])
      if !sentence.isEmpty {
        sentencesSpoken += 1
        SpeechOutput.shared.enqueue(sentence)
      }
    }
    if final {
      let rest = pendingSpeech.trimmingCharacters(in: .whitespacesAndNewlines)
      pendingSpeech = ""
      if !rest.isEmpty {
        sentencesSpoken += 1
        SpeechOutput.shared.enqueue(rest)
      }
    }
  }

  /// Index just after the first sentence end (. ! ? : or newline followed by
  /// whitespace) once at least `minChars` have accumulated.
  static func sentenceBoundary(in text: String, minChars: Int) -> String.Index? {
    guard text.count >= minChars else { return nil }
    var i = text.startIndex
    var seen = 0
    while i < text.endIndex {
      let c = text[i]
      let next = text.index(after: i)
      seen += 1
      if c == "\n", seen >= minChars { return next }
      if ".!?:؟".contains(c), seen >= minChars, next < text.endIndex, text[next].isWhitespace {
        return next  // "3.5" has no space after the dot, so decimals survive
      }
      i = next
    }
    return nil
  }

  /// A few seconds after an answer, listen for a follow-up without the wake word.
  private func listenForFollowUp() async {
    DiagLog.log("state: → follow-up window")
    pauseWakeListening()
    followUpOpen = true
    wakeStatus = "אפשר להמשיך לדבר בלי \"קלוד\"…"
    input.onPartial = { [weak self] text in self?.heardText = text }
    do {
      heardText = ""
      setPhase(.listening)
      try await input.start(language: AssistantSettings.shared.listenLanguage)
    } catch {
      followUpOpen = false
      setPhase(.idle)
      resumeWakeListening()
      return
    }
    await finishOnSilence(maxSeconds: 10, minSpeechGap: 0.9)
  }

  private func waitForSpeech() async {
    // Poll the queue lightly; speech is a few seconds at most.
    try? await Task.sleep(for: .milliseconds(300))
    let deadline = Date().addingTimeInterval(90)
    while SpeechOutput.shared.isBusy, phase == .speaking, !Task.isCancelled, Date() < deadline {
      try? await Task.sleep(for: .milliseconds(150))
    }
  }
}

/// Mutable flags shared between the streaming callbacks of one question.
@MainActor
final class AskProgress {
  var gotToken = false
  var fillerSaid = false
}
