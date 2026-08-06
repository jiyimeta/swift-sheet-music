import Foundation

/// Build identity for this copy of the engine.
///
/// On Android two separately linked images of this module coexist in one process — one inside the
/// library's own `.so`, one inside the host app's. They stay in step only because they are the same
/// build. A host compares its compiled-in stamp with the one it reads over JNI before opening an
/// edit session, and refuses to open one on a mismatch: a stale `.so` should be a locked feature
/// and a log line, never a score that silently diverges.
public enum SheetMusicEngine {
    /// Bumped by the release process alongside `CHANGELOG.md`.
    public static let version = "1.9.0"

    /// `version` as a fixed 64-bit number — FNV-1a, so both images agree without a seed.
    public static var versionStamp: Int64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in version.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01B3
        }
        return Int64(bitPattern: hash)
    }
}
