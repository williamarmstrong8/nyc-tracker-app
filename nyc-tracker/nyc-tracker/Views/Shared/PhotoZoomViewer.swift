import SwiftUI

/// Full-screen photo viewer opened by tapping any hero photo. Pages between
/// `sources` with the system paging feel, and each page is independently
/// pinch/double-tap zoomable via `ZoomableScrollView`.
struct PhotoZoomViewer: View {
    let sources: [PhotoView.Source]
    @State var currentIndex: Int

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    ZoomableScrollView {
                        PhotoView(source: source, contentMode: .fit)
                    }
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: sources.count > 1 ? .always : .never))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            closeButton
        }
        .statusBarHidden()
    }

    private var closeButton: some View {
        Button {
            Haptics.tap()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(Circle().fill(Color.black.opacity(0.4)))
        }
        .padding(.top, 8)
        .padding(.trailing, 16)
        .accessibilityLabel("Close")
    }
}
