import SwiftUI
import PhotosUI

/// State for the Squarify tab: the source picker item, the loaded source
/// image, and the rendered square output.
@MainActor
final class SquarifyViewModel: ObservableObject {

    @Published var pickerItem: PhotosPickerItem? {
        didSet { Task { await loadImage() } }
    }
    @Published private(set) var source: UIImage?
    @Published private(set) var output: UIImage?
    @Published private(set) var status: String = "Pick one image."
    @Published var isSaving = false

    private func loadImage() async {
        guard let pickerItem else {
            source = nil; output = nil
            status = "Pick one image."
            return
        }
        status = "Loading image…"
        guard let data = try? await pickerItem.loadTransferable(type: Data.self),
              let img = UIImage(data: data) else {
            status = "Couldn't load that image."
            return
        }
        source = img
        render()
    }

    private func render() {
        guard let source else { output = nil; return }
        status = "Squaring up…"
        Task.detached(priority: .userInitiated) { [source] in
            let result = ImageSquarifier.squarify(source)
            await MainActor.run {
                self.output = result
                if let out = result {
                    let px = Int(out.size.width)
                    self.status = "Output: \(px) × \(px)."
                } else {
                    self.status = "Couldn't square that image."
                }
            }
        }
    }

    func save() async {
        guard let output else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await PhotoLibrarySaver.saveImage(output)
            status = "Saved to Photos."
        } catch {
            status = error.localizedDescription
        }
    }
}
