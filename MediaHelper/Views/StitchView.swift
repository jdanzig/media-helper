import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// UI for the Stitch tab. The picker lets the user select multiple images;
/// a segmented control chooses vertical vs horizontal layout; the preview
/// shows the composite output; a Save button writes it to Photos.
@MainActor
struct StitchView: View {
    @StateObject private var vm = StitchViewModel()
    /// Index of the thumbnail currently being dragged (nil when idle).
    @State private var draggingIndex: Int? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {

                // Capture before the @Sendable PhotosPicker closure (Swift 6).
                let pickerLabel = vm.images.isEmpty
                    ? "Pick images"
                    : "Change selection (\(vm.images.count))"
                PhotosPicker(
                    selection: $vm.pickerItems,
                    maxSelectionCount: 20,
                    selectionBehavior: .ordered,
                    matching: .images
                ) {
                    Label(pickerLabel, systemImage: "photo.on.rectangle.angled")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                // Thumbnail strip — shown when 2+ images are loaded so
                // the user can long-press-drag to reorder before stitching.
                if vm.images.count > 1 {
                    thumbnailStrip
                }

                Picker("Axis", selection: $vm.axis) {
                    ForEach(StitchAxis.allCases) { axis in
                        Text(axis.label).tag(axis)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                Toggle("Divider line between images", isOn: $vm.showDivider)
                    .padding(.horizontal)

                // Preview fills remaining vertical space. ZoomableImageView
                // starts at aspect-fit scale; pinch to zoom, one finger to pan.
                Group {
                    if let out = vm.output {
                        ZoomableImageView(image: out)
                    } else {
                        ContentUnavailableView(
                            "No preview",
                            systemImage: "rectangle.on.rectangle",
                            description: Text("Pick two or more images to see a preview.")
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal)

                Text(vm.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Clear", role: .destructive) {
                        vm.clear()
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(vm.images.isEmpty)

                    Button {
                        Task { await vm.save() }
                    } label: {
                        if vm.isSaving { ProgressView() }
                        else { Label("Save to Photos", systemImage: "square.and.arrow.down") }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(vm.output == nil || vm.isSaving)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Stitch")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
    // MARK: - Thumbnail strip

    /// Horizontally scrollable row of image thumbnails.
    /// Long-press any thumbnail, then drag left or right to reorder.
    @ViewBuilder
    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // UUID is the stable identity; resolve the current index
                // inside the closure so it stays fresh after each move.
                ForEach(vm.imageIDs, id: \.self) { id in
                    let index = vm.imageIDs.firstIndex(of: id) ?? 0
                    let img   = index < vm.images.count ? vm.images[index] : UIImage()
                    ZStack(alignment: .topLeading) {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        // Order badge
                        Text("\(index + 1)")
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.black.opacity(0.6), in: Circle())
                            .padding(4)
                    }
                    .opacity(draggingIndex == index ? 0.4 : 1)
                    .onDrag {
                        draggingIndex = index
                        return NSItemProvider(object: NSString(string: "\(index)"))
                    }
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: ImageDropDelegate(
                            targetIndex: index,
                            dragging: $draggingIndex,
                            viewModel: vm
                        )
                    )
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 88)
        // Clear drag state if the user picks a completely new set of images.
        .onChange(of: vm.imageIDs) { draggingIndex = nil }
    }
}

// MARK: - Drop delegate

/// Handles live reordering as the dragged thumbnail crosses over its neighbours.
@MainActor
private struct ImageDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var dragging: Int?
    let viewModel: StitchViewModel

    /// Fires each time the drag position enters this thumbnail's frame.
    /// We immediately move the item so the strip re-orders live during the drag.
    func dropEntered(info: DropInfo) {
        guard let from = dragging, from != targetIndex else { return }
        withAnimation(.default) {
            viewModel.moveImage(
                from: IndexSet(integer: from),
                to: targetIndex > from ? targetIndex + 1 : targetIndex
            )
        }
        // Update tracking index to the new position.
        dragging = targetIndex
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

#Preview { StitchView() }
