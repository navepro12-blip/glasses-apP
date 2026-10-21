//
// AssistantPanel.swift
// Floating Claude controls on the camera screen + the settings sheet.
//

import SwiftUI
import UIKit

struct AssistantPanel: View {
  let frameProvider: @MainActor () -> UIImage?
  @State private var vm = AssistantViewModel()
  @State private var showSettings = false

  var body: some View {
    VStack(spacing: 10) {
      if !vm.heardText.isEmpty || !vm.answerText.isEmpty || vm.errorText != nil {
        VStack(alignment: .trailing, spacing: 6) {
          if !vm.heardText.isEmpty {
            Text("🗣 \(vm.heardText)")
              .foregroundStyle(.white.opacity(0.75))
          }
          if !vm.answerText.isEmpty {
            Text(vm.answerText)
              .foregroundStyle(.white)
          }
          if let err = vm.errorText {
            Text(err).foregroundStyle(.orange)
          }
        }
        .font(.system(size: 15))
        .multilineTextAlignment(.trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        .environment(\.layoutDirection, .rightToLeft)
      }

      HStack(spacing: 14) {
        Button { showSettings = true } label: {
          Image(systemName: "slider.horizontal.3")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.15), in: Circle())
        }

        Button { vm.toggleTalk() } label: {
          HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
          }
          .font(.system(size: 17, weight: .semibold))
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity)
          .frame(height: 52)
          .background(tint, in: Capsule())
        }
        .disabled(vm.phase == .thinking || !vm.hasKey)
        .opacity(vm.hasKey ? 1 : 0.5)

        Button { vm.resetConversation() } label: {
          Image(systemName: "arrow.counterclockwise")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(.white.opacity(0.15), in: Circle())
        }
      }
      if !vm.hasKey {
        Text("הוסף מפתח Anthropic בהגדרות כדי להפעיל את Claude")
          .font(.system(size: 13))
          .foregroundStyle(.white.opacity(0.8))
      }
    }
    .onAppear { vm.attach(frameProvider: frameProvider) }
    .sheet(isPresented: $showSettings, onDismiss: { vm.refreshKeyState() }) {
      AssistantSettingsView()
    }
  }

  private var title: String {
    switch vm.phase {
    case .idle: return "שאל את Claude"
    case .listening: return "מקשיב… לחץ לשליחה"
    case .thinking: return "חושב…"
    case .speaking: return "עונה… לחץ לעצירה"
    }
  }

  private var icon: String {
    switch vm.phase {
    case .idle: return "mic.fill"
    case .listening: return "paperplane.fill"
    case .thinking: return "sparkles"
    case .speaking: return "stop.fill"
    }
  }

  private var tint: Color {
    switch vm.phase {
    case .idle: return Color(red: 0.85, green: 0.47, blue: 0.34)
    case .listening: return .red
    case .thinking: return .gray
    case .speaking: return .blue
    }
  }
}

struct AssistantSettingsView: View {
  @Environment(\.dismiss) private var dismiss
  @State private var anthropicKey = AssistantSettings.shared.anthropicKey
  @State private var azureKey = AssistantSettings.shared.azureKey
  @State private var azureRegion = AssistantSettings.shared.azureRegion
  @State private var language = AssistantSettings.shared.listenLanguage
  @State private var model = AssistantSettings.shared.model
  @State private var voice = AssistantSettings.shared.hebrewVoice
  @State private var provider = AssistantSettings.shared.voiceProvider
  @State private var elevenKey = AssistantSettings.shared.elevenKey
  @State private var elevenVoiceID = AssistantSettings.shared.elevenVoiceID
  @State private var geminiKey = AssistantSettings.shared.geminiKey
  @State private var geminiVoice = AssistantSettings.shared.geminiVoice
  @State private var voiceError: String?
  @State private var useCamera = AssistantSettings.shared.useCamera
  @State private var testing = false

  var body: some View {
    NavigationStack {
      Form {
        Section {
          SecureField("sk-ant-…", text: $anthropicKey)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
          Picker("מודל", selection: $model) {
            ForEach(ClaudeModel.allCases) { Text($0.label).tag($0) }
          }
          Toggle("לשלוח את מה שהמשקפיים רואים", isOn: $useCamera)
        } header: {
          Text("Claude")
        } footer: {
          Text("המפתח נשמר רק בטלפון שלך (Keychain) ולא עולה ל-GitHub.")
        }

        Section("שפת דיבור") {
          Picker("אני מדבר ב", selection: $language) {
            ForEach(ListenLanguage.allCases) { Text($0.label).tag($0) }
          }
          .pickerStyle(.segmented)
        }

        Section {
          Picker("ספק קול", selection: $provider) {
            ForEach(VoiceProvider.allCases) { Text($0.label).tag($0) }
          }
          switch provider {
          case .apple:
            Text("קול איכותי יותר: הגדרות ← נגישות ← תוכן מוקרא ← קולות ← עברית ← להוריד Enhanced.")
              .font(.footnote)
          case .azure:
            SecureField("Azure Speech key", text: $azureKey)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Region (למשל eastus)", text: $azureRegion)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker("קול עברי", selection: $voice) {
              ForEach(HebrewVoice.allCases) { Text($0.label).tag($0) }
            }
          case .eleven:
            SecureField("ElevenLabs API key", text: $elevenKey)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Voice ID", text: $elevenVoiceID)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
          case .gemini:
            SecureField("Gemini API key (AI Studio)", text: $geminiKey)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("שם קול (Kore, Puck, Zephyr…)", text: $geminiVoice)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
          }
          Button(testing ? "משמיע…" : "בדיקת קול") {
            save()
            testing = true
            voiceError = nil
            SpeechOutput.shared.enqueue("היי נווה, ככה אני נשמע במשקפיים. בוא נבדוק אבן חדשה.")
            Task {
              try? await Task.sleep(for: .seconds(6))
              voiceError = SpeechOutput.shared.lastVoiceError
              testing = false
            }
          }
          if let voiceError {
            Text("⚠️ \(voiceError) — הושמע קול האייפון במקום").font(.footnote).foregroundStyle(.orange)
          }
        } header: {
          Text("קול")
        }
      }
      .environment(\.layoutDirection, .rightToLeft)
      .navigationTitle("הגדרות Claude")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("שמור") {
            save()
            dismiss()
          }
        }
      }
    }
  }

  private func save() {
    let s = AssistantSettings.shared
    s.anthropicKey = anthropicKey
    s.azureKey = azureKey
    s.azureRegion = azureRegion
    s.listenLanguage = language
    s.model = model
    s.hebrewVoice = voice
    s.voiceProvider = provider
    s.elevenKey = elevenKey
    s.elevenVoiceID = elevenVoiceID
    s.geminiKey = geminiKey
    s.geminiVoice = geminiVoice
    s.useCamera = useCamera
  }
}
