import SwiftUI

/// Shared UI for "which backend + which outputs" — reused by both the
/// Download tab and the Transcribe tab so they stay in sync.
///
/// The parent supplies bindings for the selections and backend choices,
/// plus a `speakerLabels` flag for AssemblyAI. Capability rules (which
/// backends are available, which options are supported) are computed
/// from the models.
struct TranscriptionOptionsView: View {
    @Binding var selections: OutputSelections
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
                checkRow("Original video",
                         systemImage: "video",
                         checked: selections.saveOriginalVideo) {
                    selections.saveOriginalVideo.toggle()
                }
                checkRow("Video with subtitles",
                         systemImage: "captions.bubble",
                         checked: selections.subtitles == .original) {
                    selections.subtitles = selections.subtitles == .original ? .none : .original
                }
                checkRow("Video with translated subtitles",
                         systemImage: "captions.bubble.fill",
                         checked: selections.subtitles == .translated) {
                    selections.subtitles = selections.subtitles == .translated ? .none : .translated
                }
                checkRow("Transcript",
                         systemImage: "doc.text",
                         checked: selections.transcript == .original) {
                    selections.transcript = selections.transcript == .original ? .none : .original
                }
                checkRow("Transcript with English translation",
                         systemImage: "doc.text.fill",
                         checked: selections.transcript == .translated) {
                    selections.transcript = selections.transcript == .translated ? .none : .translated
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
                    Label("This backend doesn't support translation. Choose a different backend.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Private

    @ViewBuilder
    private func checkRow(_ title: String,
                          systemImage: String,
                          checked: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .foregroundStyle(checked ? AnyShapeStyle(.tint) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
    }

    private func backendRow(_ b: TranscriptionBackend) -> some View {
        let available = availability[b] ?? false
        let selected = backend == b
        return Button {
            if available { backend = b }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(available
                                     ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                                     : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(b.displayName)
                        .foregroundStyle(available
                                         ? AnyShapeStyle(HierarchicalShapeStyle.primary)
                                         : AnyShapeStyle(HierarchicalShapeStyle.secondary))
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

    private var backendSupportsTranslationIfNeeded: Bool {
        guard selections.needsTranslation else { return true }
        return backend.capabilities.supportsTranslationToEnglish
    }
}
