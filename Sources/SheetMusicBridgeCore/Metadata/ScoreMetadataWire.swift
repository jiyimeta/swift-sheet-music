import SheetMusicFoundation
import Wirelet

/// Score metadata payload returned across JNI. The wire format is
/// `i32 titleByteLen + UTF-8 + i32 composerByteLen + UTF-8` per
/// `@WireFormat`'s synthesized encoding (legacy positional shape;
/// switches to TLV in Task 3).
@WireFormat
package struct ScoreMetadataWire {
    package var title: String
    package var composer: String

    /// Explicit because a synthesized memberwise initializer is `internal` regardless of the type's
    /// own access level, and SheetMusicAndroidJNI constructs this across the module boundary.
    package init(title: String, composer: String) {
        self.title = title
        self.composer = composer
    }
}
