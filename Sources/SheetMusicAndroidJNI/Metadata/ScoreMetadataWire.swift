import Foundation
import Wirelet

/// Score metadata payload returned across JNI. The wire format is
/// `i32 titleByteLen + UTF-8 + i32 composerByteLen + UTF-8` per
/// `@WireFormat`'s synthesized encoding (legacy positional shape;
/// switches to TLV in Task 3).
@WireFormat
struct ScoreMetadataWire {
    var title: String
    var composer: String
}
