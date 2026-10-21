//
// Diagnostics.swift
// In-app diagnostics log (ring buffer) for the voice pipeline: audio session
// route/category changes, engine starts, recogniser results and errors, TTS
// timings. Shown in the settings sheet ("יומן אבחון") with a Copy button.
//

@preconcurrency import AVFoundation
import Foundation
import SwiftUI
import os

final class DiagLog: Sendable {
  static let shared = DiagLog()
  private let state = OSAllocatedUnfairLock(initialState: [String]())
  private let limit = 240

  nonisolated static func log(_ message: String) {
    shared.add(message)
  }

  func add(_ message: String) {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss.SSS"
    let line = "\(f.string(from: Date())) \(message)"
    state.withLock { lines in
      lines.append(line)
      if lines.count > limit { lines.removeFirst(lines.count - limit) }
    }
    NSLog("[NaveGlasses] %@", message)
  }

  func snapshot() -> [String] { state.withLock { $0 } }
  func text() -> String { snapshot().joined(separator: "\n") }
  func clear() { state.withLock { $0.removeAll() } }

  /// Describes the current audio session in one line.
  nonisolated static func sessionLine() -> String {
    let s = AVAudioSession.sharedInstance()
    let ins = s.currentRoute.inputs.map { "\($0.portName)/\($0.portType.rawValue)" }.joined(separator: ",")
    let outs = s.currentRoute.outputs.map { "\($0.portName)/\($0.portType.rawValue)" }.joined(separator: ",")
    return "cat=\(s.category.rawValue) mode=\(s.mode.rawValue) sr=\(Int(s.sampleRate)) in=[\(ins)] out=[\(outs)]"
  }

  /// Logs every audio-session change for the lifetime of the app.
  nonisolated(unsafe) private static var observers: [NSObjectProtocol] = []
  private static let observersLock = NSLock()

  static func observeAudioSession() {
    observersLock.lock()
    defer { observersLock.unlock() }
    guard observers.isEmpty else { return }
    let nc = NotificationCenter.default
    observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil) { note in
      let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) ?? 0
      DiagLog.log("route change reason=\(reason) → \(sessionLine())")
    })
    observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: nil) { note in
      let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
      DiagLog.log("interruption type=\(type == 1 ? "began" : "ended")")
    })
    observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { _ in
      DiagLog.log("engine configuration change")
    })
    observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil) { _ in
      DiagLog.log("media services reset")
    })
  }
}

/// Scrollable log with Copy / Clear, refreshed once a second.
struct DiagnosticsView: View {
  @State private var copied = false

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      ScrollViewReader { proxy in
        ScrollView {
          let lines = DiagLog.shared.snapshot()
          LazyVStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
              Text(line)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Color.clear.frame(height: 1).id("end")
          }
          .padding(10)
          .environment(\.layoutDirection, .leftToRight)
        }
        .onAppear { proxy.scrollTo("end", anchor: .bottom) }
      }
    }
    .navigationTitle("יומן אבחון")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button(copied ? "הועתק ✓" : "העתק") {
          UIPasteboard.general.string = DiagLog.sessionLine() + "\n" + DiagLog.shared.text()
          copied = true
          Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
          }
        }
      }
      ToolbarItem(placement: .topBarLeading) {
        Button("נקה") { DiagLog.shared.clear() }
      }
    }
  }
}
