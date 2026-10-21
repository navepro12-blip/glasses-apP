//
// AssistantViewModel.swift
// Voice loop: wake word / tap → listen → (grab glasses frame) → Claude →
// speak in the ear → short follow-up window → back to wake-word listening.
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
  @ObservationIgnored private var tapObservers: [NSObjectProtocol] = []
  @ObservationIgnored private var listeningFromTap = false
  @ObservationIgnored private var history: [ChatTurn] = []
  @ObservationIgnored private var frameProvider: @MainActor () -> UIImage? = { nil }
  @ObservationIgnored private let toolBox = ToolBox()
  @ObservationIgnored private var attached = false
  @ObservationIgnored private var followUpCancelled = false
  @ObservationIgnored private var errorClearTask: Task<Void, Never>?
  @ObservationIgnored private var watchdogTask: Task<Void, Never>?
  @ObservationIgnored private var phaseSince = Date()
  /// Streaming answer: text not yet cut into a sentence for TTS.
  @ObservationIgnored private var pendingSpeech = ""
  @ObservationIgnored private var sentencesSpoken = 0

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
    tapObservers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated {
        DiagLog.log("app: background — releasing the microphone")
        self?.wake.releaseEngine()
        self?.wakeActive = false
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
      wake.releaseEngine()
      wakeActive = false
      if phase == .listening { input.cancel(); setPhase(.idle) }
      wakeStatus = "התחל סשן כדי לדבר עם Claude"
    }
  }

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
          self.input.cancel()
          SpeechOutput.shared.stopAll()
          self.followUpOpen = false
          self.setPhase(.idle)
          self.showError("האפליקציה נתקעה ואופסה — נסה שוב")
          self.resumeWakeListening()
        } else if self.phase == .idle, self.sessionReady, self.wakeEnabled, self.hasKey, !self.wake.isRunning, stuck > 10 {
          DiagLog.log("watchdog: idle but not listening — restarting the wake listener")
          self.resumeWakeListening()
        }
      }
    }
  }

  private func setPhase(_ p: Phase) {
    if p != phase { phaseSince = Date() }
    phase = p
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
    if on { resumeWakeListening() } else { wake.releaseEngine(); wakeActive = false }
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
    guard sessionReady else {
      wakeStatus = "התחל סשן כדי לדבר עם Claude"
      wakeActive = false
      return
    }
    guard phase == .idle, !wake.isRunning else {
      DiagLog.log("state: wake not (re)started — phase=\(phase) wakeRunning=\(wake.isRunning)")
      return
    }
    wakeStatus = "מפעיל האזנה…"
    DiagLog.log("state: → wake listening")
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
    wake.stop(keepRoute: true)
    wakeActive = false
  }

  /// Called when the settings sheet closes: keys / language / toggles may have changed.
  func refreshKeyState() {
    hasKey = !AssistantSettings.shared.anthropicKey.isEmpty
    if AssistantSettings.shared.locationEnabled { LocationContext.shared.start() } else { LocationContext.shared.stop() }
    wakeEnabled = AssistantSettings.shared.wakeWordEnabled
    guard phase == .idle else { return }
    if wakeEnabled { pauseWakeListening() } else { wake.releaseEngine(); wakeActive = false }
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
      setPhase(.idle)
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
      if prompt != nil {
        // Hands-free: nobody will tap "send", so end on silence.
        Task { await self.finishOnSilence(maxSeconds: 10, minSpeechGap: 1.0) }
      }
    } catch {
      setPhase(.idle)
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
      setPhase(.idle)
      if !followUpOpen { showError("לא שמעתי כלום — נסה שוב.") }
      followUpOpen = false
      heardText = ""
      resumeWakeListening()
      return
    }
    await finishAndAsk()
  }

  private func finishAndAsk() async {
    var question = await input.finish()
    // "קלוד, …" said inside the follow-up / push-to-talk window: drop the name.
    if let tail = WakeWord.commandAfterWakeWord(in: question), !tail.isEmpty { question = tail }
    DiagLog.log("state: captured (ptt/follow-up=\(followUpOpen)) '\(question.prefix(40))'")
    heardText = question
    guard !question.isEmpty else {
      setPhase(.idle)
      if !followUpOpen { showError("לא שמעתי כלום — נסה שוב.") }
      followUpOpen = false
      resumeWakeListening()
      return
    }
    followUpOpen = false
    await ask(question)
  }

  private func ask(_ question: String) async {
    let endOfSpeech = Date()
    pauseWakeListening()
    heardText = question
    errorText = nil
    setPhase(.thinking)
    // Instant acknowledgement: the question was captured, Claude is thinking.
    Chime.playDone()
    SpeechOutput.shared.beginTrace(at: endOfSpeech)
    DiagLog.log("latency: question captured '\(question.prefix(40))' input=\(AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName ?? "?")")
    let settings = AssistantSettings.shared
    let jpeg = settings.useCamera ? frameProvider().flatMap { ClaudeClient.jpeg($0) } : nil
    let client = ClaudeClient(apiKey: settings.anthropicKey, model: settings.model.rawValue, tools: toolBox)
    pendingSpeech = ""
    sentencesSpoken = 0
    answerText = ""
    var firstToken: Date?
    do {
      let answer = try await client.ask(history: history, question: question, imageJPEG: jpeg) { [weak self] delta in
        guard let self else { return }
        if firstToken == nil {
          firstToken = Date()
          DiagLog.log("latency: first token \(Int(Date().timeIntervalSince(endOfSpeech) * 1000)) ms after end of speech")
          self.setPhase(.speaking)
        }
        self.answerText += delta
        self.pendingSpeech += delta
        self.flushSentences(final: false)
      }
      answerText = answer
      flushSentences(final: true)
      if sentencesSpoken == 0 { SpeechOutput.shared.enqueue(answer) }
      history.append(ChatTurn(role: "user", text: question))
      history.append(ChatTurn(role: "assistant", text: answer))
      if history.count > 12 { history.removeFirst(history.count - 12) }
      setPhase(.speaking)
      await waitForSpeech()
      DiagLog.log("latency: answer fully spoken \(Int(Date().timeIntervalSince(endOfSpeech) * 1000)) ms after end of speech")
      guard phase == .speaking else { return }  // stopped by the user
      setPhase(.idle)
      if settings.followUpEnabled {
        await listenForFollowUp()
        return
      }
    } catch {
      DiagLog.log("claude: failed — \(error)")
      SpeechOutput.shared.stopAll()
      setPhase(.idle)
      showError(error.localizedDescription)
      SpeechOutput.shared.enqueue("הייתה תקלה, נסה שוב.")
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
  /// whitespace/end) once at least `minChars` have accumulated.
  static func sentenceBoundary(in text: String, minChars: Int) -> String.Index? {
    guard text.count >= minChars else { return nil }
    var i = text.startIndex
    var seen = 0
    while i < text.endIndex {
      let c = text[i]
      let next = text.index(after: i)
      seen += 1
      if c == "\n" && seen >= minChars { return next }
      if ".!?:؟".contains(c), seen >= minChars {
        // ". " or end — but not a decimal like 3.5 or an abbreviation like 925.5
        if next == text.endIndex { return nil }  // wait for more: might be "3." then digits
        if text[next].isWhitespace { return next }
      }
      i = next
    }
    return nil
  }

  /// A few seconds after an answer, listen for a follow-up without the wake word.
  private func listenForFollowUp() async {
    DiagLog.log("state: → follow-up window")
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
    await finishOnSilence(maxSeconds: 8, minSpeechGap: 0.9)
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
