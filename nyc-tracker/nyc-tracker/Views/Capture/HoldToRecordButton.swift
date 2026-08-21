import SwiftUI

/// Hold-to-record voice memo control. Press-and-hold begins recording; release ends it and
/// hands the final result to `onFinish`. Uses `RecorderProtocol` so the real speech
/// recorder can drop in without touching this view.
///
/// Always renders as a small pill — recording is one of two ways to fill the description
/// (the other being typing directly), so the button doesn't need to dominate the screen.
/// Once a recording has been captured, the label switches to "Re-record"; re-pressing and
/// holding it re-records and overwrites the transcript.
struct HoldToRecordButton: View {
    var recorder: any RecorderProtocol
    var hasRecording: Bool
    var onFinish: (RecordingResult) -> Void

    @State private var isPressed = false

    var body: some View {
        let title = recorder.isRecording
            ? String(format: "Recording… %.1fs", recorder.elapsed)
            : (hasRecording ? "Re-record" : "Hold to record")

        Button {
            // Tap is a no-op; interaction is via long-press gesture below.
        } label: {
            HStack(spacing: 6) {
                Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .symbolEffect(.pulse, options: .repeating, isActive: recorder.isRecording)
                Text(title)
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
        .scaleEffect(isPressed ? 0.98 : 1.0)
        .animation(.snappy(duration: 0.18), value: isPressed)
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
