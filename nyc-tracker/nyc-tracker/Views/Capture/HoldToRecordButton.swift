import SwiftUI

/// Hold-to-record voice memo control. Press-and-hold begins recording; release ends it and
/// hands the final result to `onFinish`. Uses `RecorderProtocol` so the real speech
/// recorder can drop in without touching this view.
///
/// Renders as a large inviting button before a transcript exists, then collapses into a
/// small "Re-record" pill once a transcript has been captured — re-pressing and holding it
/// re-records and overwrites the transcript.
struct HoldToRecordButton: View {
    var recorder: any RecorderProtocol
    var hasRecording: Bool
    var onFinish: (RecordingResult) -> Void

    @State private var isPressed = false

    private var isCompact: Bool { hasRecording && !recorder.isRecording }

    var body: some View {
        let title = recorder.isRecording
            ? "Recording…"
            : (hasRecording ? "Re-record" : "Hold to record")
        let subtitle = recorder.isRecording
            ? String(format: "%.1fs", recorder.elapsed)
            : "Talk about the place. Release to stop."

        Button {
            // Tap is a no-op; interaction is via long-press gesture below.
        } label: {
            if isCompact {
                HStack(spacing: 6) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .symbolEffect(.pulse, options: .repeating, isActive: recorder.isRecording)
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 132)
                .padding(.vertical, 8)
            }
        }
        .buttonStyle(.glass)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.snappy(duration: 0.18), value: isPressed)
        .animation(.snappy(duration: 0.22), value: isCompact)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed {
                        isPressed = true
                        Haptics.tap()
                        recorder.start()
                    }
                }
                .onEnded { _ in
                    isPressed = false
                    Task {
                        let result = await recorder.stop()
                        onFinish(result)
                    }
                }
        )
    }
}
