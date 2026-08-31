import SheetMusicFoundation
import Wirelet

/// Score metadata payload returned across JNI. The bytes are wirelet
/// TLV per `@WireFormat`'s synthesized encoding: for each field, a tag
/// varint (`tag << 3 | wireType`) followed by a varint byte length and
/// the UTF-8 payload.
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
