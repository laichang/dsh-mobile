import DSHCore
import SwiftUI
import UIKit

extension EnvironmentValues {
    /// The transcriber of the mic key. The app sets it at the root (`AppModel`): the Speech
    /// framework, or in Debug the fake of `-DSHMFakeSpeech`.
    @Entry var transcriber: TranscriberFactory = SpeechFrameworkTranscriber.factory
}

/// The mic key on a composer (STORY §7, voice): a tap starts to listen and the
/// words go into the field as the user speaks; a second tap stops. It never sends.
struct MicKey: View {
    let dictation: Dictation
    let identifier: String
    var disabled = false
    let read: @MainActor () -> String
    let write: @MainActor (String) -> Void
    @Environment(\.transcriber) private var transcriber

    var body: some View {
        let listening = dictation.isActive
        Button {
            dictation.toggle(using: transcriber, read: read, write: write)
        } label: {
            Group {
                if dictation.state == .starting {
                    ProgressView().tint(DSHTheme.textPrimary)
                } else if listening {
                    Image(systemName: "waveform")
                        .font(.body.weight(.semibold))
                        .symbolEffect(.variableColor.iterative, isActive: true)
                } else {
                    Image(systemName: "mic").font(.body.weight(.semibold))
                }
            }
            .foregroundStyle(listening ? Color.white : DSHTheme.textSecondary)
            .frame(width: 40, height: 40)
            .background(listening ? DSHTheme.blue : Color.white.opacity(0.08), in: .circle)
        }
        .disabled(disabled && !listening)
        .accessibilityLabel(listening ? Text("Stop dictation", tableName: "Voice") : Text("Dictate", tableName: "Voice"))
        .accessibilityValue(listening ? "listening" : "idle")
        .accessibilityIdentifier(identifier)
    }
}

/// The line above the field: "listening", or why dictation can't start and how to turn it
/// on. When it is not allowed, the field stays as it was.
struct DictationNotice: View {
    let dictation: Dictation

    var body: some View {
        switch dictation.state {
        case .idle:
            EmptyView()
        case .starting, .listening:
            HStack(spacing: 6) {
                Circle().fill(DSHTheme.blue).frame(width: 7, height: 7).accessibilityHidden(true)
                Text("Listening… Tap the mic again when you are done. Nothing is sent until you tap send.", tableName: "Voice")
            }
            .font(.footnote)
            .foregroundStyle(DSHTheme.textSecondary)
            .accessibilityElement(children: .combine)
            .accessibilityValue("listening")
            .accessibilityIdentifier("voice.notice")
        case .notAllowed(let permission):
            notice(Self.text(for: permission), token: Self.token(for: permission), settings: permission == .denied)
        case .failed(let message):
            notice(Text("The speech did not become text: \(message)", tableName: "Voice"), token: "failed", settings: false)
        }
    }

    private func notice(_ text: Text, token: String, settings: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "mic.slash").accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                text
                    .accessibilityValue(token)
                    .accessibilityIdentifier("voice.notice")
                if settings {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    } label: {
                        Text("Open Settings", tableName: "Voice").fontWeight(.semibold)
                    }
                    .foregroundStyle(DSHTheme.blue)
                    .accessibilityIdentifier("voice.openSettings")
                }
            }
            Spacer(minLength: 0)
            Button { dictation.clearNotice() } label: { Image(systemName: "xmark").font(.caption.weight(.semibold)) }
                .foregroundStyle(DSHTheme.textTertiary)
                .accessibilityLabel(Text("Close", tableName: "Voice"))
        }
        .font(.footnote)
        .foregroundStyle(DSHTheme.amber)
    }

    static func text(for permission: DictationPermission) -> Text {
        switch permission {
        case .denied: Text("Voice input is off. To turn it on, open Settings › dsh-mobile and turn on Microphone and Speech Recognition.", tableName: "Voice")
        case .restricted: Text("This iPhone does not allow speech recognition (Screen Time or device management).", tableName: "Voice")
        case .unavailable, .granted: Text("Speech to text is not available for this language on this iPhone.", tableName: "Voice")
        }
    }

    static func token(for permission: DictationPermission) -> String {
        switch permission {
        case .denied: "denied"
        case .restricted: "restricted"
        case .unavailable, .granted: "unavailable"
        }
    }
}
