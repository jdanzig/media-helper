import SwiftUI
import PhotosUI

/// Transcribe tab. User picks a video from Photos, chooses output
/// preset + backend, hits Start, and gets whichever artifacts were
/// requested. Videos go to Photos; `.srt` / `.txt` files are offered
/// through the share sheet.
struct TranscribeView: View {
    @StateObject private var vm = TranscribeViewModel()
    @State private var shareItems: [URL] = []
    @State private var isSharePresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Video") {
                    PhotosPicker(selection: $vm.pickerItem,
                                 matching: .videos,
                                 photoLibrary: .shared()) {
                        Label(vm.pickedVideoName ?? "Pick a video",
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
                    preset: $vm.preset,
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
            .sheet(isPresented: $isSharePresented) {
                ShareSheet(items: shareItems)
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var statusView: some View {
        switch vm.phase {
        case .idle:
            Text("Pick a video and hit Start.")
                .font(.footnote).foregroundStyle(.secondary)
        case .loadingVideo:
            Text("Loading video…").font(.footnote).foregroundStyle(.secondary)
        case .running(let phase, let frac):
            Text(phase.label).font(.footnote).foregroundStyle(.secondary)
            ProgressView(value: frac)
            Text("\(Int(frac * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        case .done:
            Label("Done — outputs below.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.footnote)
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
                shareItems = [srt]
                isSharePresented = true
            } label: {
                Label("Share .srt file", systemImage: "square.and.arrow.up")
            }
        }
        if let txt = o.transcriptFileURL {
            Button {
                shareItems = [txt]
                isSharePresented = true
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
