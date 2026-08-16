import Foundation

/// Local, on-disk storage for photos and voice notes. Files live under Application Support in
/// subdirectories keyed by kind; the model rows keep only relative paths, so the base directory can
/// change (e.g. under an App Group later) without invalidating existing records.
enum FileStorage {
    enum Kind: String {
        case photos = "Photos"
        case audio = "Audio"
    }

    static let baseDirectory: URL = {
        let fm = FileManager.default
        let root = (try? fm.url(for: .applicationSupportDirectory,
                                in: .userDomainMask,
                                appropriateFor: nil,
                                create: true))
            ?? fm.temporaryDirectory
        var base = root.appendingPathComponent("NYCLog", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)

        // Application Support is included in iCloud/iTunes backups by default.
        //
        // Everything under here is either already in the user's photo library or
        // already in Supabase, so backing it up duplicates the whole library into
        // the user's iCloud quota to no benefit. It also used to mean voice-memo
        // audio left the device inside a backup — that file is now deleted the
        // moment transcription ends, but excluding the directory means a future
        // transient file can't reintroduce the problem by accident.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? base.setResourceValues(values)

        return base
    }()

    static func directory(for kind: Kind) -> URL {
        let dir = baseDirectory.appendingPathComponent(kind.rawValue, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Persist `data` under a new file inside `kind`'s directory, returning both the URL and the
    /// relative path (which is what we store on the SwiftData row).
    @discardableResult
    static func writeData(_ data: Data, kind: Kind, fileExtension: String) throws -> (url: URL, relativePath: String) {
        let filename = "\(UUID().uuidString).\(fileExtension)"
        let url = directory(for: kind).appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return (url, "\(kind.rawValue)/\(filename)")
    }

    /// Reserve a URL without writing to it (used for AVAudioRecorder, which needs a target URL).
    static func reserveURL(kind: Kind, fileExtension: String) -> (url: URL, relativePath: String) {
        let filename = "\(UUID().uuidString).\(fileExtension)"
        let url = directory(for: kind).appendingPathComponent(filename)
        return (url, "\(kind.rawValue)/\(filename)")
    }

    /// Resolve a relative path back to an absolute URL for reading.
    static func url(forRelativePath path: String) -> URL {
        baseDirectory.appendingPathComponent(path)
    }

    /// Delete a file, ignoring "it wasn't there".
    ///
    /// Named for intent rather than mechanism: call sites are places where the
    /// file must not survive, and a silent `try?` at each of them reads like an
    /// afterthought. (No secure-erase pass — on an APFS device with data
    /// protection the block-level guarantee is the encryption, not overwriting.)
    static func shred(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Remove every file in the audio directory.
    ///
    /// Called once on launch. `SpeechRecorder.stop()` already deletes each
    /// recording as it finishes, but that path does not run if the app is killed
    /// or crashes mid-transcription — and a leftover recording is precisely the
    /// thing that must not accumulate. This is the backstop that makes the
    /// invariant "no audio on disk between sessions" true regardless of how the
    /// last session ended.
    ///
    /// Safe to be unconditional: nothing references an audio file across a
    /// launch. The transcript is the only durable artifact.
    @discardableResult
    static func purgeAudioDirectory() -> Int {
        let fm = FileManager.default
        let dir = directory(for: .audio)
        guard let contents = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return 0 }

        var removed = 0
        for url in contents {
            do {
                try fm.removeItem(at: url)
                removed += 1
            } catch {
                // Leave it; next launch tries again.
            }
        }
        return removed
    }
}
