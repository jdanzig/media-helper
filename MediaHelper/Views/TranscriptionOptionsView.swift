import SwiftUI

/// Shared UI for "which backend + which outputs" — reused by both the
/// Download tab and the Transcribe tab so they stay in sync.
///
/// The parent supplies bindings for the preset and backend choices,
/// plus a `speakerLabels` flag for AssemblyAI. Capability rules (which
/// backends are available, which options are supported) are computed
/// from the models.
struct TranscriptionOptionsView: View {
    @Binding var preset: TranscriptionPreset
    @Binding var backend: TranscriptionBackend
    @Binding var speakerLabels: Bool

    /// Re-evaluated every render so the gray state reflects reality (the
    /// user may have just entered an API key in the Settings tab).
    private var availability: [TranscriptionBackend: Bool] {
        Dictionary(uniqueKeysWithValues: TranscriptionBackend.allCases.map {
            ($0, TranscriptionServiceFactory.isAvailable($0))
        })
    }

    var body: some View {
        Group {
            Section("Outputs") {
                ForEach(TranscriptionPreset.allCases) { p in
                    Button {
                        preset = p
                    } label: {
                        HStack {
                            Image(systemName: preset == p ? "largecircle.fill.circle"
                                                          : "circle")
                                .foregroundStyle(.tint)
                            Text(p.title)
                                .foregroundStyle(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Transcription backend") {
                ForEach(TranscriptionBackend.allCases) { b in
                    backendRow(b)
                }

                if backend.capabilities.supportsSpeakerDiarization {
                    Toggle("Speaker labels", isOn: $speakerLabels)
                }

                if !backendSupportsTranslationIfNeeded {
                    Label("This backend doesn't support translation. Pick Video + (translated) subtitles with a different backend.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: -

    private func backendRow(_ b: TranscriptionBackend) -> some View {
        let available = availability[b] ?? false
        let selected = backend == b
        return Button {
            if available { backend = b }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(available ? .tint : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.displayName)
                        .foregroundStyle(available ? .primary : .secondary)
                    Text(available ? b.tagline : unavailableReason(b))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .disabled(!available)
    }

    private func unavailableReason(_ b: TranscriptionBackend) -> String {
        switch b {
        case .whisperKit:    return "Add the WhisperKit Swift Package in Xcode to enable."
        case .openAIWhisper: return "Add an OpenAI API key in Settings."
        case .assemblyAI:    return "Add an AssemblyAI API key in Settings."
        }
    }

    /// True unless the user asked for translation with a backend that
    /// can't do it. Catches the AssemblyAI + "translated subs" combo.
    private var backendSupportsTranslationIfNeeded: Bool {
        let needsTranslation = preset == .videoWithTranslatedSubs || preset == .everything
        if !needsTranslation { return true }
        return backend.capabilities.supportsTranslationToEnglish
    }
}
