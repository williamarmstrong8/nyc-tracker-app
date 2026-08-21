import Foundation

/// FNV-1a, used wherever a string has to become a filename.
///
/// Not `Hasher`. Swift seeds `Hasher` per process, so its values differ between
/// launches — a cache keyed on it would orphan every file it wrote on each cold
/// start while those files still counted against the size cap, which is the
/// worst of both outcomes: nothing hits and the disk fills anyway.
enum StableHash {

    static func hash(_ string: String) -> UInt64 {
        var value: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            value ^= UInt64(byte)
            value = value &* 0x100000001b3
        }
        return value
    }

    /// Fixed-width hex, so filenames sort and truncate predictably.
    static func filenameToken(_ string: String) -> String {
        String(format: "%016llx", hash(string))
    }
}
