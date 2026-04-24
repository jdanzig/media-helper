import Foundation
import PhotosUI
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers

/// Transcribe tab state. Handles:
///   - PhotosPicker selection of a video from the user's library.
///   - Copying the picked video to a local temp file (PhotosPicker hands
///     you a sandboxed URL that disappears quickly, so we materialize
///     it as a regular file before the pipeline gets hold of it).
///   - Driving the shared `TranscriptionPipeline` and surfacing progress.
///   - Holding the final outputs so the view can offer share / save.
@MainActor
final class TranscribeViewModel: ObservableObject {

    @Published var pickerItem: PhotosPickerItem? {
        didSet { Task { await loadSelected() } }
    }
    @Published private(set) var pickedVideoURL: URL?
    @Published private(set) var pickedVideoName: String?

    @Published var preset: TranscriptionPreset = .videoWithSubs
    @Published var backend: TranscriptionBackend = TranscriptionServiceFactory.defaultAvailableBackend()
    @Published var speakerLabels: Bool = false

    enum RunPhase: Equatable {
        case idle
        case loadingVideo
        case running(TranscriptionPipeline.Phase, Double)
        case done
        case failed(String)
    }

    @Published private(set) var phase: RunPhase = .idle
    @Published private(set) var outputs: TranscriptionOutputs?

    private var currentTask: Task<Void, Never>?

    // MARK: - Video loading

    /// Copy the selected PhotosPicker video to a temp file we own.
    private func loadSelected() async {
        guard let item = pickerItem else {
            pickedVideoURL = nil
            pickedVideoName = nil
            return
        }
        phase = .loadingVideo
        do {
            guard let movie = try await item.loadTransferable(type: MovieFile.self) else {
                throw DownloadError.saveFailed("couldn't read selected video")
            }
            // Copy to a stable temp path — the URL we get back points at
            // a temp that PhotosPicker may reap.
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(movie.url.pathExtension.isEmpty ? "mov" : movie.url.pathExtension)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: movie.url, to: dest)
            pickedVideoURL = dest
            pickedVideoName = dest.lastPathComponent
            phase = .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Pipeline

    func start() {
        guard let videoURL = pickedVideoURL else { return }
        currentTask?.cancel()
        let opts = preset.options(withSpeakerLabels: speakerLabels)
        let backend = self.backend

        currentTask = Task {
            phase = .running(.extractingAudio, 0)
            outputs = nil
            do {
                let result = try await TranscriptionPipeline.run(
                    videoURL: videoURL,
                    backend: backend,
                    options: opts,
                    onProgress: { [weak self] update in
                        Task { @MainActor [weak self] in
                            self?.phase = .running(update.phase, update.fraction)
                        }
                    }
                )
                outputs = result
                phase = .done
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        pickerItem = nil
        pickedVideoURL = nil
        pickedVideoName = nil
        outputs = nil
        phase = .idle
    }
}

/// Bridge for PhotosPicker → file URL. PhotosPicker's Transferable
/// machinery returns a file that lives inside the picker's temporary
/// sandbox; we wrap it in a struct so we can copy it out.
struct MovieFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            MovieFile(url: received.file)
        }
    }
}
