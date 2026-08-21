import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The photo section on both edit screens — the same drag-to-reorder
/// horizontal strip as the capture flow's `ReorderablePhotoStrip`, plus what
/// that one doesn't need: a red minus badge on each thumbnail to remove it,
/// and a trailing "add" card that reopens the same picker the capture flow
/// uses.
///
/// Deletion, reordering and ingestion are handed back to the caller rather
/// than owned here, because the two edit screens hold genuinely different
/// photo types underneath — an in-flight `PhotosPickerItem` array for the
/// capture draft, a persisted `Photo` relationship (on-disk files, a sync
/// queue) for a saved visit — and only the caller knows which one it's
/// holding.
struct EditablePhotoStrip: View {
    let sources: [PhotoView.Source]
    var thumbnailWidth: CGFloat = 140
    var thumbnailHeight: CGFloat = 140 * 4 / 3
    var cornerRadius: CGFloat = 16
    var maxPhotos: Int = 8
    var onDelete: (Int) -> Void
    var onMove: (IndexSet, Int) -> Void
    var onAdd: ([PhotosPickerItem]) -> Void

    @State private var draggedIndex: Int?
    @State private var showPicker = false
    @State private var pickerSelection: [PhotosPickerItem] = []

    private var remainingSlots: Int { max(1, maxPhotos - sources.count) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                    thumbnail(source: source, index: index)
                }
                addCard
            }
        }
        .photosPicker(
            isPresented: $showPicker,
            selection: $pickerSelection,
            maxSelectionCount: remainingSlots,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickerSelection) { _, items in
            guard !items.isEmpty else { return }
            onAdd(items)
            pickerSelection = []
        }
    }

    private func thumbnail(source: PhotoView.Source, index: Int) -> some View {
        PhotoView(source: source, contentMode: .fill)
            .frame(width: thumbnailWidth, height: thumbnailHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .opacity(draggedIndex == index ? 0.4 : 1)
            .overlay(alignment: .topTrailing) {
                deleteButton(index: index)
            }
            .onDrag {
                draggedIndex = index
                return NSItemProvider(object: String(index) as NSString)
            }
            .onDrop(
                of: [.text],
                delegate: PhotoReorderDropDelegate(
                    targetIndex: index,
                    onMove: onMove,
                    draggedIndex: $draggedIndex
                )
            )
    }

    private func deleteButton(index: Int) -> some View {
        Button {
            Haptics.tap()
            onDelete(index)
        } label: {
            Image(systemName: "minus.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .font(.system(size: 22))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
        }
        .padding(6)
    }

    private var addCard: some View {
        Button {
            Haptics.tap()
            showPicker = true
        } label: {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(width: thumbnailWidth, height: thumbnailHeight)
                .overlay {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct PhotoReorderDropDelegate: DropDelegate {
    let targetIndex: Int
    let onMove: (IndexSet, Int) -> Void
    @Binding var draggedIndex: Int?

    func dropEntered(info: DropInfo) {
        guard let from = draggedIndex, from != targetIndex else { return }

        withAnimation(.default) {
            onMove(
                IndexSet(integer: from),
                targetIndex > from ? targetIndex + 1 : targetIndex
            )
        }
        Haptics.soft()
        draggedIndex = targetIndex
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedIndex = nil
        return true
    }
}
