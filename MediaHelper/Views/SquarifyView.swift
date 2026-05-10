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

    // Combined live transforms.
    private var totalScale: CGFloat {
        confirmedScale * gestureScale
    }
    private var totalOffset: CGSize {
        CGSize(width:  confirmedOffset.width  + gestureOffset.width,
               height: confirmedOffset.height + gestureOffset.height)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {

                // MARK: Picker button
                PhotosPicker(
                    selection: $vm.pickerItem,
                    matching: .images
                ) {
                    Label(
                        vm.source == nil ? "Pick image" : "Change image",
                        systemImage: "photo"
                    )
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

                // MARK: Save button
                Button {
                    Task {
                        await vm.save(scale:      totalScale,
                                      offset:     totalOffset,
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
                .disabled(vm.source == nil || vm.isSaving)
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
                    .scaleEffect(totalScale)
                    .offset(totalOffset)
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
        // confirmed values.
        .gesture(
            MagnificationGesture()
                .updating($gestureScale) { value, state, _ in
                    state = value
                }
                .onEnded { value in
                    confirmedScale = max(0.1, confirmedScale * value)
                }
                .simultaneously(with:
                    DragGesture()
                        .updating($gestureOffset) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            confirmedOffset = CGSize(
                                width:  confirmedOffset.width  + value.translation.width,
                                height: confirmedOffset.height + value.translation.height
                            )
                        }
                )
        )
    }
}

#Preview { SquarifyView() }
