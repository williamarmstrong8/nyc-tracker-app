import SwiftUI

/// Horizontally paged photo carousel. Uses a `ScrollView` with paging behavior instead of
/// `TabView(.page)` — the latter fights the enclosing vertical `ScrollView` for gestures and often
/// swallows the first swipe or leaves the page half-scrolled.
struct PhotoCarousel: View {
    let sources: [PhotoView.Source]

    @State private var currentIndex: Int?
    @State private var showZoom = false

    var body: some View {
        if sources.isEmpty {
            emptyPlaceholder
        } else {
            ZStack(alignment: .bottom) {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<sources.count, id: \.self) { index in
                            Color.clear
                                .containerRelativeFrame(.horizontal)
                                .frame(maxHeight: .infinity)
                                .overlay {
                                    PhotoView(source: sources[index], contentMode: .fill)
                                }
                                .clipped()
                                .id(index)
                                .onTapGesture {
                                    Haptics.tap()
                                    showZoom = true
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentIndex)
                .scrollIndicators(.hidden)
                .scrollDisabled(sources.count <= 1)
                .onAppear {
                    if currentIndex == nil { currentIndex = 0 }
                }

                if sources.count > 1 {
                    pageDots
                        .padding(.bottom, 10)
                }
            }
            .fullScreenCover(isPresented: $showZoom) {
                PhotoZoomViewer(sources: sources, currentIndex: currentIndex ?? 0)
            }
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(0..<sources.count, id: \.self) { i in
                Circle()
                    .fill(Color.white.opacity((currentIndex ?? 0) == i ? 0.95 : 0.45))
                    .frame(width: 6, height: 6)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
            }
        }
        .animation(.snappy, value: currentIndex)
        .allowsHitTesting(false)
    }

    private var emptyPlaceholder: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            Image(systemName: "photo")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }
}
