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
    /// Index of the thumbnail the drag is currently hovering over.
    @State private var hoveringIndex: Int? = nil

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
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        // Order badge — top-left
                        .overlay(alignment: .topLeading) {
                            Text("\(index + 1)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(3)
                                .background(.black.opacity(0.6), in: Circle())
                                .padding(4)
                        }
                        // Remove button — top-right
                        .overlay(alignment: .topTrailing) {
                            Button { vm.removeImage(at: index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.65))
                                    .font(.system(size: 18))
                            }
                            .buttonStyle(.plain)
                            .offset(x: 5, y: -5)
                        }
                    .opacity(draggingIndex == index ? 0.4 : 1)
                    // Highlight the slot where the dragged item will land.
                    .overlay {
                        if hoveringIndex == index && draggingIndex != index {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(.tint, lineWidth: 2.5)
                        }
                    }
                    .onDrag {
                        draggingIndex = index
                        return NSItemProvider(object: NSString(string: "\(index)"))
                    }
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: ImageDropDelegate(
                            targetIndex: index,
                            dragging: $draggingIndex,
                            hovering: $hoveringIndex,
                            viewModel: vm
                        )
                    )
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 88)
        // Clear drag state if the user picks a completely new set of images.
        .onChange(of: vm.imageIDs) { draggingIndex = nil; hoveringIndex = nil }
    }
}

// MARK: - Drop delegate

/// Commits the reorder when the drag is released.
///
/// Reordering used to happen live in dropEntered, but calling moveImage()
/// there triggers a SwiftUI re-render which re-lays-out the HStack mid-drag.
/// That scrambles the drop zones so the gesture ends after just one step —
/// the "only moves by one" bug.  By doing nothing to the data during the
/// drag and committing only in performDrop, the layout stays stable for the
/// full gesture, so the item lands wherever the user actually releases it.
@MainActor
private struct ImageDropDelegate: DropDelegate {
    let targetIndex: Int
    @Binding var dragging: Int?
    @Binding var hovering: Int?
    let viewModel: StitchViewModel

    func dropEntered(info: DropInfo) {
        hovering = targetIndex
    }

    func dropExited(info: DropInfo) {
        if hovering == targetIndex { hovering = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; hovering = nil }
        guard let from = dragging, from != targetIndex else { return true }
        viewModel.moveImage(
            from: IndexSet(integer: from),
            to: targetIndex > from ? targetIndex + 1 : targetIndex
        )
        return true
    }
}

#Preview { StitchView() }
