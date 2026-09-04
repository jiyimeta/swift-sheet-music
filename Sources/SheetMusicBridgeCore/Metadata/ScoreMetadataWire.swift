import SheetMusicCore
import SheetMusicFoundation
import Wirelet

/// One entry of `Score.metaTags`. A nested struct rather than two parallel `[String]` fields
/// because Wirelet can append an `Optional` to a struct with zero byte movement but can never
/// pair up two independently-decoded arrays if one of them is ever truncated.
@WireFormat
package struct MetaTagWire {
    package var key: String
    package var value: String

    /// Explicit because a synthesized memberwise initializer is `internal` regardless of the type's
    /// own access level, and SheetMusicAndroidJNI constructs this across the module boundary.
    package init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// Score metadata payload returned across JNI. The bytes are wirelet
/// TLV per `@WireFormat`'s synthesized encoding: for each field, a tag
/// varint (`tag << 3 | wireType`) followed by a varint byte length and
/// the UTF-8 payload.
@WireFormat
package struct ScoreMetadataWire {
    package var title: String
    package var composer: String
    /// Every entry of `Score.metaTags`, sorted by key.
    ///
    /// `title` and `composer` predate this and stay: they are the two keys every host reads, and
    /// removing them would break every Kotlin call site for no gain. They are mirrors of
    /// `workTitle` / `composer` in this array, not a separate source of truth.
    ///
    /// NOTE — no declared default, unlike `LayoutOptionsWire.showsLyrics`. The Kotlin emitter
    /// translates scalar literals only (`KotlinLiteral.translate` returns nil for anything else)
    /// and *fails the build* rather than silently dropping a default it cannot carry, so `= []`
    /// here breaks codegen with `untranslatableDefault`. The generated `data class` therefore takes
    /// `metaTags` as a required parameter.
    ///
    /// That costs nothing here: this payload is decode-only on the Kotlin side — `ScoreMetadata`
    /// reads it, nothing constructs it — and the wire itself is unaffected, since an absent
    /// repeated field decodes to an empty array either way. The Swift memberwise initializer below
    /// keeps its own `= []`, which is a parameter default and independent of the field's.
    package var metaTags: [MetaTagWire]

    /// Explicit because a synthesized memberwise initializer is `internal` regardless of the type's
    /// own access level, and SheetMusicAndroidJNI constructs this across the module boundary.
    package init(title: String, composer: String, metaTags: [MetaTagWire] = []) {
        self.title = title
        self.composer = composer
        self.metaTags = metaTags
    }
}

extension ScoreMetadataWire {
    /// The whole `metaTags` dictionary, key-sorted.
    ///
    /// The sort is load-bearing, not tidiness: `Score.metaTags` is a `Dictionary`, whose iteration
    /// order is seeded per process, so an unsorted encode would produce different bytes for the same
    /// score on every run. A host diffing the blob to decide whether to re-render, or a gate
    /// comparing two encodes, would see phantom changes.
    package init(score: Score) {
        self.init(
            title: score.metaTags["workTitle"] ?? "",
            composer: score.metaTags["composer"] ?? "",
            metaTags: score.metaTags.keys.sorted().map {
                MetaTagWire(key: $0, value: score.metaTags[$0] ?? "")
            },
        )
    }
}
