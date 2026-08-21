import SwiftUI
import PhotosUI

/// A horizontal photo strip with a lifted, direct-manipulation reorder gesture.
/// The dragged thumbnail is rendered above the carousel while its original
/// slot stays empty, nearby thumbnails animate into their new positions, and
/// holding the thumbnail near either edge scrolls toward the remaining photos.
struct ReorderablePhotoStrip: View {
    @Binding var items: [PhotosPickerItem]
    var thumbnailWidth: CGFloat
    var thumbnailHeight: CGFloat
    var cornerRadius: CGFloat

    /// Each selection gets a local identity because the same Photos asset may
    /// legitimately be selected twice.
    @State private var entries: [PhotoEntry]
    @State private var frames: [UUID: CGRect] = [:]
    @State private var viewportWidth: CGFloat = 0
    @State private var draggedID: UUID?
    @State private var dragLocation: CGPoint?
    @State private var grabOffset: CGSize = .zero
    @State private var lastSwapTargetID: UUID?
    @State private var coordinateSpaceName = UUID()

    init(
        items: Binding<[PhotosPickerItem]>,
        thumbnailWidth: CGFloat,
        thumbnailHeight: CGFloat,
        cornerRadius: CGFloat
    ) {
        _items = items
        self.thumbnailWidth = thumbnailWidth
        self.thumbnailHeight = thumbnailHeight
        self.cornerRadius = cornerRadius
        _entries = State(
            initialValue: items.wrappedValue.map { PhotoEntry(item: $0) }
        )
    }

    var body: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .topLeading) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(entries) { entry in
                            thumbnail(for: entry)
                                .opacity(draggedID == entry.id ? 0 : 1)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: PhotoFramePreferenceKey.self,
                                            value: [
                                                entry.id: geometry.frame(
                                                    in: .named(coordinateSpaceName)
                                                )
                                            ]
                                        )
                                    }
                                }
                                .simultaneousGesture(reorderGesture(for: entry.id))
                        }
                    }
                }

                if let draggedEntry, let overlayPosition {
                    thumbnail(for: draggedEntry)
                        .allowsHitTesting(false)
                        .scaleEffect(1.06)
                        .shadow(color: .black.opacity(0.22), radius: 16, y: 8)
                        .position(overlayPosition)
                        .zIndex(1)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            .coordinateSpace(name: coordinateSpaceName)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: PhotoStripWidthPreferenceKey.self,
                        value: geometry.size.width
                    )
                }
            }
            .onPreferenceChange(PhotoFramePreferenceKey.self) { newFrames in
                frames = newFrames
                reorderIfNeeded()
            }
            .onPreferenceChange(PhotoStripWidthPreferenceKey.self) { newWidth in
                viewportWidth = newWidth
            }
            .onChange(of: items) { _, newItems in
                syncEntries(with: newItems)
            }
            .task(id: draggedID) {
                guard draggedID != nil else { return }
                while !Task.isCancelled, draggedID != nil {
                    try? await Task.sleep(for: .milliseconds(70))
                    guard !Task.isCancelled else { return }
                    autoScroll(using: proxy)
                }
            }
        }
    }

    private var draggedEntry: PhotoEntry? {
        guard let draggedID else { return nil }
        return entries.first { $0.id == draggedID }
    }

    private var overlayPosition: CGPoint? {
        guard let dragLocation else { return nil }
        return CGPoint(
            x: dragLocation.x - grabOffset.width,
            y: dragLocation.y - grabOffset.height
        )
    }

    private func thumbnail(for entry: PhotoEntry) -> some View {
        PhotoView(source: .pickerItem(entry.item), contentMode: .fill)
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func reorderGesture(for id: UUID) -> some Gesture {
        LongPressGesture(minimumDuration: 0.2, maximumDistance: 12)
            .sequenced(
                before: DragGesture(
                    minimumDistance: 0,
                    coordinateSpace: .named(coordinateSpaceName)
                )
            )
            .onChanged { value in
                guard case .second(true, let dragValue) = value,
                      let dragValue else { return }

                if draggedID == nil {
                    beginDrag(id: id, at: dragValue.location)
                }

                guard draggedID == id else { return }
                dragLocation = dragValue.location
                reorderIfNeeded()
            }
            .onEnded { _ in
                finishDrag()
            }
    }

    private func beginDrag(id: UUID, at location: CGPoint) {
        guard let frame = frames[id] else { return }
        dragLocation = location
        grabOffset = CGSize(
            width: location.x - frame.midX,
            height: location.y - frame.midY
        )
        Haptics.soft()
        withAnimation(.snappy(duration: 0.2, extraBounce: 0.08)) {
            draggedID = id
        }
    }

    private func reorderIfNeeded() {
        guard let draggedID,
              let centerX = overlayPosition?.x,
              let fromIndex = entries.firstIndex(where: { $0.id == draggedID })
        else { return }

        // Moving back across the dragged thumbnail's empty destination slot
        // arms the previous neighbor again, allowing a smooth direction change.
        if let draggedFrame = frames[draggedID],
           draggedFrame.minX...draggedFrame.maxX ~= centerX {
            lastSwapTargetID = nil
            return
        }

        guard let target = entries.first(where: { entry in
            guard entry.id != draggedID, let frame = frames[entry.id] else { return false }
            return frame.minX...frame.maxX ~= centerX
        }),
        target.id != lastSwapTargetID,
        let targetIndex = entries.firstIndex(where: { $0.id == target.id })
        else { return }

        lastSwapTargetID = target.id
        withAnimation(.snappy(duration: 0.24, extraBounce: 0)) {
            entries.move(
                fromOffsets: IndexSet(integer: fromIndex),
                toOffset: targetIndex > fromIndex ? targetIndex + 1 : targetIndex
            )
            items = entries.map(\.item)
        }
        Haptics.soft()
    }

    private func autoScroll(using proxy: ScrollViewProxy) {
        guard let draggedID,
              let location = dragLocation,
              viewportWidth > 0,
              let index = entries.firstIndex(where: { $0.id == draggedID })
        else { return }

        let edgeZone: CGFloat = 52
        let destinationID: UUID?
        let anchor: UnitPoint

        if location.x >= viewportWidth - edgeZone, index < entries.count - 1 {
            destinationID = entries[index + 1].id
            anchor = .trailing
        } else if location.x <= edgeZone, index > 0 {
            destinationID = entries[index - 1].id
            anchor = .leading
        } else {
            destinationID = nil
            anchor = .center
        }

        guard let destinationID else { return }
        withAnimation(.linear(duration: 0.12)) {
            proxy.scrollTo(destinationID, anchor: anchor)
        }
    }

    private func finishDrag() {
        guard draggedID != nil else { return }
        withAnimation(.snappy(duration: 0.22, extraBounce: 0.06)) {
            draggedID = nil
            dragLocation = nil
        }
        grabOffset = .zero
        lastSwapTargetID = nil
        items = entries.map(\.item)
    }

    private func syncEntries(with newItems: [PhotosPickerItem]) {
        // Internal reorders already have matching entries and stable IDs. A
        // picker update is rebuilt so newly selected photos get fresh IDs.
        guard newItems != entries.map(\.item) else { return }
        draggedID = nil
        dragLocation = nil
        grabOffset = .zero
        lastSwapTargetID = nil
        entries = newItems.map { PhotoEntry(item: $0) }
    }
}

private struct PhotoEntry: Identifiable {
    let id = UUID()
    let item: PhotosPickerItem
}

private struct PhotoFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct PhotoStripWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
