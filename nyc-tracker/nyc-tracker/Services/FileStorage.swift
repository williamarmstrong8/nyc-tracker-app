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
        let base = root.appendingPathComponent("NYCLog", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
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
}
