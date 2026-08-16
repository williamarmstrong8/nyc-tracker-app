import Foundation
import SwiftUI
import AVFoundation
import Speech

/// The result of a hold-to-record voice memo. Callers get both the finalized transcript and, if
/// available, the URL to the on-disk audio file so it can be attached to the Visit.
struct RecordingResult: Sendable {
    var transcript: String
    var audioRelativePath: String?
}

/// Protocol for a hold-to-record voice memo capture + on-device transcription.
/// The UI depends only on this so the real recorder and any test double can be swapped in.
@MainActor
protocol RecorderProtocol: AnyObject, Observable {
    var isRecording: Bool { get }
    var elapsed: TimeInterval { get }
    func start()
    /// Ends recording and returns the finalized transcript + optional audio file path.
    func stop() async -> RecordingResult
}

// MARK: - Real recorder

/// Real recorder: writes an M4A to Application Support and transcribes it on-device with the
/// modern Speech framework. Falls back to SFSpeechRecognizer if SpeechAnalyzer isn't available.
@MainActor
@Observable
final class SpeechRecorder: RecorderProtocol {
    private(set) var isRecording: Bool = false
    private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var audioRelativePath: String?
    private var startedAt: Date?
    private var timerTask: Task<Void, Never>?

    func start() {
        guard !isRecording else { return }
        elapsed = 0
        startedAt = Date()

        Task { [weak self] in
            guard let self else { return }
            let ok = await self.prepareSession()
            guard ok else { return }
            await MainActor.run {
                self.beginRecording()
            }
        }
    }

    func stop() async -> RecordingResult {
        guard isRecording else { return RecordingResult(transcript: "", audioRelativePath: nil) }
        isRecording = false
        timerTask?.cancel()
        timerTask = nil
        recorder?.stop()
        let capturedURL = audioURL
        let capturedRelative = audioRelativePath
        recorder = nil
        audioURL = nil
        audioRelativePath = nil
        elapsed = 0
        startedAt = nil

        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        guard let url = capturedURL, FileManager.default.fileExists(atPath: url.path) else {
            return RecordingResult(transcript: "", audioRelativePath: nil)
        }
        let transcript = await Self.transcribe(fileAt: url)
        return RecordingResult(transcript: transcript, audioRelativePath: capturedRelative)
    }

    // MARK: - Session setup

    private func prepareSession() async -> Bool {
        // Mic permission
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else { return false }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }

    private func beginRecording() {
        let reserved = FileStorage.reserveURL(kind: .audio, fileExtension: "m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        do {
            let recorder = try AVAudioRecorder(url: reserved.url, settings: settings)
            recorder.isMeteringEnabled = false
            guard recorder.record() else { return }
            self.recorder = recorder
            self.audioURL = reserved.url
            self.audioRelativePath = reserved.relativePath
            self.isRecording = true

            timerTask = Task { [weak self] in
                while let self, self.isRecording {
                    try? await Task.sleep(for: .milliseconds(100))
                    if let started = self.startedAt {
                        await MainActor.run {
                            self.elapsed = Date().timeIntervalSince(started)
                        }
                    }
                }
            }
        } catch {
            // Silently ignore — caller will get an empty transcript back from stop().
        }
    }

    // MARK: - Transcription

    /// Transcribe the audio file at `url` on-device. Tries the modern SpeechTranscriber first,
    /// falls back to SFSpeechRecognizer, and returns an empty string as a last resort.
    static func transcribe(fileAt url: URL) async -> String {
        // Authorize Speech recognition — needed for both paths.
        let authorized = await requestSpeechAuthorization()
        guard authorized else { return "" }

        if let modern = await transcribeUsingSpeechAnalyzer(url: url) {
            return modern
        }
        if let legacy = await transcribeUsingSFSpeechRecognizer(url: url) {
            return legacy
        }
        return ""
    }

    private static func requestSpeechAuthorization() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        switch current {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default: return false
        }
    }

    private static func transcribeUsingSpeechAnalyzer(url: URL) async -> String? {
        // SpeechTranscriber lives in the modern Speech module (iOS 26+) and is not available on
        // the simulator or older devices; we detect that and let the caller fall back.
        guard SpeechTranscriber.isAvailable else { return nil }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) else {
            return nil
        }

        do {
            let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)

            // Make sure the model assets are on-device.
            if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await install.downloadAndInstall()
            }

            let audioFile = try AVAudioFile(forReading: url)
            let analyzer = SpeechAnalyzer(modules: [transcriber])

            var collected = AttributedString("")
            let resultsTask = Task {
                do {
                    for try await result in transcriber.results {
                        collected.append(result.text)
                    }
                } catch {
                    // Ignore mid-stream errors and return whatever we have.
                }
            }

            let lastTime = try await analyzer.analyzeSequence(from: audioFile)
            if let lastTime {
                try await analyzer.finalizeAndFinish(through: lastTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
            await resultsTask.value
            let plain = String(collected.characters)
            return plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : plain
        } catch {
            return nil
        }
    }

    private static func transcribeUsingSFSpeechRecognizer(url: URL) async -> String? {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current), recognizer.isAvailable else {
            return nil
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        // Force on-device when supported so we honor "everything on-device".
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.shouldReportPartialResults = false

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            var didResume = false
            recognizer.recognitionTask(with: request) { result, error in
                if didResume { return }
                if let result, result.isFinal {
                    didResume = true
                    continuation.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    didResume = true
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Stub recorder (Previews / tests)

@MainActor
@Observable
final class StubRecorder: RecorderProtocol {
    private(set) var isRecording: Bool = false
    private(set) var elapsed: TimeInterval = 0
    private var startedAt: Date?
    private var timerTask: Task<Void, Never>?

    func start() {
        guard !isRecording else { return }
        isRecording = true
        startedAt = Date()
        elapsed = 0
        timerTask = Task { [weak self] in
            while let self, self.isRecording {
                try? await Task.sleep(for: .milliseconds(100))
                if let started = self.startedAt {
                    self.elapsed = Date().timeIntervalSince(started)
                }
            }
        }
    }

    func stop() async -> RecordingResult {
        guard isRecording else { return RecordingResult(transcript: "", audioRelativePath: nil) }
        isRecording = false
        timerTask?.cancel()
        timerTask = nil
        let duration = elapsed
        startedAt = nil
        elapsed = 0
        return RecordingResult(transcript: Self.stubTranscript(duration: duration), audioRelativePath: nil)
    }

    private static func stubTranscript(duration: TimeInterval) -> String {
        if duration < 1.0 {
            return "Quick stop. Loved the vibe."
        }
        return """
        Popped in tonight and it was great. The room felt warm without being loud, \
        we ordered a couple small plates and one bigger dish to share. The service \
        was easy, unhurried. Would come back and bring people.
        """
    }
}
