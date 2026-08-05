import SwiftUI
import PhotosUI

/// Transcribe tab. User picks a video from Photos, chooses output
/// preset + backend, hits Start, and gets whichever artifacts were
/// requested. Videos go to Photos; `.srt` / `.txt` files are offered
/// through the share sheet.
@MainActor
struct TranscribeView: View {
    @StateObject private var vm = TranscribeViewModel()
    @State private var shareFile: ShareFile? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    // Capture into a local let so the @MainActor-isolated
                    // property isn't referenced directly inside the
                    // @Sendable PhotosPicker content closure (Swift 6).
                    let videoName = vm.pickedVideoName ?? "Pick a video"
                    PhotosPicker(selection: $vm.pickerItem,
                                 matching: .videos,
                                 photoLibrary: .shared()) {
                        Label(videoName,
                              systemImage: "photo.on.rectangle.angled")
                    }

                    if case .loadingVideo = vm.phase {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Loading selected video…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }

                TranscriptionOptionsView(
                    selections: $vm.selections,
                    backend: $vm.backend,
                    speakerLabels: $vm.speakerLabels
                )

                Section("Status") {
                    statusView
                }

                Section {
                    Button {
                        vm.start()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!canStart)

                    if case .done = vm.phase, let outputs = vm.outputs {
                        outputsView(outputs)
                    }

                    Button("Clear", role: .destructive) { vm.reset() }
                        .disabled(vm.pickedVideoURL == nil && vm.outputs == nil)
                }
            }
            .navigationTitle("Transcribe")
            .sheet(item: $shareFile) { file in
                ShareSheet(items: [file.url])
            }
        }
    }

    // MARK: - Subviews

    private struct StepInfo {
        let phase: TranscriptionPipeline.Phase
        let label: String
    }

    // Steps expected for the current selections. Stable during a run
    // because the Start button is disabled while one is in progress.
    private var runSteps: [StepInfo] {
        let opts = vm.selections.toTranscriptionOptions()
        var s: [StepInfo] = [
            .init(phase: .extractingAudio, label: "Extract audio"),
            .init(phase: .transcribing,    label: "Transcribe"),
        ]
        if opts.burnInSubtitles { s.append(.init(phase: .burningSubtitles, label: "Burn subtitles")) }
        s.append(.init(phase: .savingFiles, label: "Save"))
        return s
    }

    @ViewBuilder
    private var statusView: some View {
        switch vm.phase {
        case .idle:
            Text("Pick a video and hit Start.")
                .font(.footnote).foregroundStyle(.secondary)
        case .loadingVideo:
            Text("Loading video…").font(.footnote).foregroundStyle(.secondary)
        case .running(let activePhase, let frac):
            pipelineStepList(active: activePhase, fraction: frac)
        case .done:
            pipelineStepList(active: nil, fraction: 1.0)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
        }
    }

    @ViewBuilder
    private func pipelineStepList(active: TranscriptionPipeline.Phase?,
                                   fraction: Double) -> some View {
        let order: [TranscriptionPipeline.Phase] = [
            .extractingAudio, .transcribing, .burningSubtitles, .savingFiles
        ]
        let activeIdx = active.flatMap { order.firstIndex(of: $0) } ?? Int.max

        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(runSteps.enumerated()), id: \.offset) { _, step in
                let stepIdx  = order.firstIndex(of: step.phase) ?? 0
                let isDone   = stepIdx < activeIdx
                let isActive = stepIdx == activeIdx
                let iconName: String = isDone   ? "checkmark.circle.fill"
                                     : isActive ? "circle.fill"
                                     :            "circle"
                let iconColor: Color = isDone   ? .green
                                     : isActive ? .accentColor
                                     :            Color(.tertiaryLabel)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: iconName)
                        .foregroundStyle(iconColor)
                        .frame(width: 20)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.label)
                            .opacity(isDone || isActive ? 1.0 : 0.4)

                        if isActive {
                            if let pct = stepFraction(step.phase, global: fraction) {
                                ProgressView(value: pct)
                                Text("\(Int(pct * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
    }

    // Returns a 0–1 fraction for the active step's own progress bar.
    // extractingAudio and savingFiles are too short to show a meaningful
    // bar, so they get an indeterminate spinner (nil).
    private func stepFraction(_ phase: TranscriptionPipeline.Phase,
                               global: Double) -> Double? {
        switch phase {
        case .extractingAudio:  return nil
        case .transcribing:     return min(max(global - 0.10, 0) / 0.60, 1.0)
        case .burningSubtitles: return min(max(global - 0.70, 0) / 0.25, 1.0)
        case .savingFiles:      return nil
        case .done:             return nil
        }
    }

    @ViewBuilder
    private func outputsView(_ o: TranscriptionOutputs) -> some View {
        if o.videoURL != nil {
            Label("Saved original to Photos", systemImage: "photo.stack")
                .font(.footnote)
        }
        if o.subtitledVideoURL != nil {
            Label("Saved subtitled video to Photos", systemImage: "captions.bubble.fill")
                .font(.footnote)
        }
        if let srt = o.subtitleFileURL {
            Button {
                shareFile = ShareFile(url: srt)
            } label: {
                Label("Share .srt file", systemImage: "square.and.arrow.up")
            }
        }
        if let txt = o.transcriptFileURL {
            Button {
                shareFile = ShareFile(url: txt)
            } label: {
                Label("Share transcript (.txt)", systemImage: "square.and.arrow.up")
            }
        }
    }

    private var canStart: Bool {
        guard vm.pickedVideoURL != nil else { return false }
        switch vm.phase {
        case .running, .loadingVideo: return false
        default: return true
        }
    }
}

/// Identifiable wrapper so a URL can be used with `.sheet(item:)`.
/// Using `.sheet(item:)` guarantees the sheet content is always built
/// with the correct URL — unlike `.sheet(isPresented:)` + a separate
/// items array, which can race if SwiftUI evaluates the content closure
/// before the companion state update lands, producing a blank share sheet.
struct ShareFile: Identifiable {
    let id = UUID()
    let url: URL
}

/// Thin UIViewControllerRepresentable wrapper around `UIActivityViewController`.
/// Used for the "share .srt / .txt" buttons. Videos go to Photos directly,
/// so they don't route through here.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview { TranscribeView() }
