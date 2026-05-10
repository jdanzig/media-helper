import SwiftUI
import PhotosUI

/// UI for the Squarify tab.
///
/// The user picks a rectangular image. It appears centred on a square canvas
/// whose background colour matches the top-left pixel of the source (same rule
/// as `ImageSquarifier`). Pinch zooms the image within the canvas; drag
/// repositions it. The "Save" button renders whatever is currently visible into
/// a full-resolution square UIImage and saves it to Photos.
@MainActor
struct SquarifyView: View {
    @StateObject private var vm = SquarifyViewModel()

    // In-progress gesture deltas — @GestureState resets automatically when
    // the gesture ends, so we never have to manually zero these.
    @GestureState private var gestureScale:  CGFloat = 1.0
    @GestureState private var gestureOffset: CGSize  = .zero

    // Accumulated values from completed gestures.
    @State private var confirmedScale:  CGFloat = 1.0
    @State private var confirmedOffset: CGSize  = .zero

    // Actual display width of the square canvas, captured at layout time.
    @State private var canvasSize: CGFloat = 300

    // Combined live transforms (unclamped).
    private var totalScale:  CGFloat { confirmedScale * gestureScale }
    private var totalOffset: CGSize  {
        CGSize(width:  confirmedOffset.width  + gestureOffset.width,
               height: confirmedOffset.height + gestureOffset.height)
    }

    /// Pan extent clamped so the image always covers the canvas.
    ///
    /// At default zoom (image fits inside canvas) → max offset = 0, no panning.
    /// Zoomed in beyond the canvas → panning is allowed up to the point where
    /// the image edge aligns with the canvas edge.
    private var displayOffset: CGSize {
        guard let source = vm.source else { return .zero }
        return clampOffset(totalOffset, source: source, scale: totalScale)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {

                // MARK: Picker button
                // Capture before the @Sendable PhotosPicker closure (Swift 6).
                let pickerLabel = vm.source == nil ? "Pick image" : "Change image"
                PhotosPicker(
                    selection: $vm.pickerItem,
                    matching: .images
                ) {
                    Label(pickerLabel, systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)

                // MARK: Square canvas
                squareCanvas
                    .padding(.horizontal)

                // MARK: Reset button (only shown when image is loaded)
                if vm.source != nil {
                    Button("Reset position") {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            confirmedScale  = 1.0
                            confirmedOffset = .zero
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                // MARK: Status line
                Text(vm.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                // MARK: Clear + Save buttons
                HStack(spacing: 12) {
                    Button("Clear", role: .destructive) {
                        vm.clear()
                        confirmedScale  = 1.0
                        confirmedOffset = .zero
                    }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .disabled(vm.source == nil)

                    Button {
                        Task {
                            await vm.save(scale:      totalScale,
                                          offset:     displayOffset,
                                          canvasSize: canvasSize)
                        }
                    } label: {
                        if vm.isSaving {
                            ProgressView()
                        } else {
                            Label("Save to Photos", systemImage: "square.and.arrow.down")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                    .disabled(vm.source == nil || vm.isSaving)
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle("Squarify")
            .navigationBarTitleDisplayMode(.inline)
            // Reset transforms when a new image is loaded.
            .onChange(of: vm.source) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                    confirmedScale  = 1.0
                    confirmedOffset = .zero
                }
            }
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private var squareCanvas: some View {
        ZStack {
            // Background fill — matches the squarification colour.
            Color(uiColor: vm.backgroundColor)

            if let source = vm.source {
                Image(uiImage: source)
                    .resizable()
                    .scaledToFit()
                    // Fill the full canvas frame so .scaleEffect pivots
                    // around the canvas centre, not the image's own centre.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scaleEffect(totalScale)
                    .offset(displayOffset)
            } else {
                ContentUnavailableView(
                    "No image",
                    systemImage: "square.dashed",
                    description: Text("Pick a rectangular image.")
                )
            }
        }
        // Keep the canvas square regardless of screen width.
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        // Capture the actual display size so renderSquare can scale offsets
        // from display-point space to output-pixel space correctly.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { canvasSize = geo.size.width }
                    .onChange(of: geo.size.width) { canvasSize = geo.size.width }
            }
        )
        // Pinch to zoom + drag to reposition, simultaneously.
        // @GestureState means the in-progress deltas reset to identity when
        // each gesture ends; the .onEnded handlers fold them into the
        // confirmed values (with clamping applied).
        .gesture(
            MagnificationGesture()
                .updating($gestureScale) { value, state, _ in
                    state = value
                }
                .onEnded { value in
                    let newScale = max(0.1, confirmedScale * value)
                    confirmedScale = newScale
                    // Re-clamp offset for the new (possibly smaller) scale.
                    if let source = vm.source {
                        confirmedOffset = clampOffset(confirmedOffset,
                                                      source: source,
                                                      scale: newScale)
                    }
                }
                .simultaneously(with:
                    DragGesture()
                        .updating($gestureOffset) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            let raw = CGSize(
                                width:  confirmedOffset.width  + value.translation.width,
                                height: confirmedOffset.height + value.translation.height
                            )
                            if let source = vm.source {
                                confirmedOffset = clampOffset(raw,
                                                              source: source,
                                                              scale: confirmedScale)
                            } else {
                                confirmedOffset = raw
                            }
                        }
                )
        )
    }

    // MARK: - Offset clamping

    /// Returns `offset` clamped so the image (at `scale`) never leaves a gap
    /// between its edge and the canvas edge.
    ///
    /// When the image fits entirely inside the canvas (default zoom), the
    /// allowed range is exactly zero — the image stays centred and cannot be
    /// dragged at all. When zoomed beyond the canvas the image can be panned
    /// up to the point where its far edge reaches the canvas edge.
    private func clampOffset(_ offset: CGSize,
                              source: UIImage,
                              scale: CGFloat) -> CGSize {
        guard canvasSize > 0 else { return .zero }
        let fitScale = min(canvasSize / source.size.width,
                           canvasSize / source.size.height)
        let imgW = source.size.width  * fitScale * scale
        let imgH = source.size.height * fitScale * scale
        let maxX = max(0, (imgW - canvasSize) / 2)
        let maxY = max(0, (imgH - canvasSize) / 2)
        return CGSize(
            width:  min(maxX, max(-maxX, offset.width)),
            height: min(maxY, max(-maxY, offset.height))
        )
    }
}

#Preview { SquarifyView() }
