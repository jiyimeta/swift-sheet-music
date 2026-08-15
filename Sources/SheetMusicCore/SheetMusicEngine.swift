import Foundation

/// Build identity for this copy of the engine.
///
/// On Android two separately linked images of this module coexist in one process — one inside the
/// library's own `.so`, one inside the host app's. They stay in step only because they are the same
/// build. This type gives a host something to compare: its own compiled-in stamp against the one it
/// reads over JNI, before opening an edit session, so it can refuse to open one on a mismatch. No
/// host performs that comparison yet — this is the primitive, not the enforcement.
public enum SheetMusicEngine {
    /// Bumped by hand alongside `CHANGELOG.md` when this is tagged as a release — there is no automated release
    /// process that does this; a hand-edited test is the only thing currently enforcing the bump.
    ///
    /// Both images compute `versionStamp` from this same source constant, so the mismatch gate only fires when the
    /// two builds carry different version *strings*. A stale `.so` left over from a local rebuild at an unchanged
    /// version is exactly the case this is blind to — the historical failure this mechanism was added to catch.
    ///
    /// This is a WORK-IN-PROGRESS stamp, not a released one: the `-w9` suffix marks a build published
    /// only to a local `~/.m2` while the notation work is in flight. It exists so the locally built
    /// artifact and the eventual tagged one stamp DIFFERENTLY — with both carrying "1.15.0", a host
    /// that kept a stale local `.so` in its Gradle cache after re-pinning to the tag would read the
    /// number it expected and the gate above would be blind to exactly the case it was added for.
    /// The bump to the plain release string is a release-only commit and is never published locally.
    public static let version = "1.15.0-w9"

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
