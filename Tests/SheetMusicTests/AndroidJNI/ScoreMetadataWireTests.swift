#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import Testing

    /// `ScoreMetadataWire` carried `title` and `composer` alone, so an Android host could not show a
    /// copyright line, an arranger or a lyricist that the file plainly states — the whole
    /// `Score.metaTags` dictionary is what an Apple host reads. These pin the map's round trip and the
    /// deterministic ordering the encoder owes a byte-comparison gate.
    struct ScoreMetadataWireTests {
        @Test
        func metaTagsRoundTrip() throws {
            let wire = ScoreMetadataWire(
                title: "Sonata",
                composer: "Anon.",
                metaTags: [
                    MetaTagWire(key: "arranger", value: "A. Arranger"),
                    MetaTagWire(key: "composer", value: "Anon."),
                    MetaTagWire(key: "copyright", value: "Public Domain"),
                    MetaTagWire(key: "lyricist", value: "L. Lyricist"),
                    MetaTagWire(key: "workTitle", value: "Sonata"),
                ],
            )
            let decoded = try ScoreMetadataWire(decoding: wire.encodeToData())
            #expect(decoded.title == "Sonata")
            #expect(decoded.composer == "Anon.")
            #expect(decoded.metaTags.count == 5)
            #expect(decoded.metaTags.first { $0.key == "copyright" }?.value == "Public Domain")
            #expect(decoded.metaTags.first { $0.key == "lyricist" }?.value == "L. Lyricist")
        }

        /// The field is appended with a default so a host built against the two-field shape still
        /// decodes. Omitting it must therefore mean "no tags", not a decode failure.
        @Test
        func omittedMetaTagsDecodeAsEmpty() throws {
            let wire = ScoreMetadataWire(title: "T", composer: "C")
            let decoded = try ScoreMetadataWire(decoding: wire.encodeToData())
            #expect(decoded.metaTags.isEmpty)
        }

        /// `Score.metaTags` is a Dictionary, whose iteration order is not stable across runs. The
        /// bridge sorts by key so two encodes of one score produce identical bytes — the property the
        /// MSCX idempotency gate depends on, applied here to the metadata blob.
        @Test
        func bridgeSortsTagsByKey() {
            var score = Score(division: 480, parts: [])
            score.metaTags = [
                "workTitle": "Sonata",
                "composer": "Anon.",
                "copyright": "Public Domain",
                "arranger": "A. Arranger",
            ]
            let wire = ScoreMetadataWire(score: score)
            #expect(wire.metaTags.map(\.key) == ["arranger", "composer", "copyright", "workTitle"])
            #expect(wire.title == "Sonata")
            #expect(wire.composer == "Anon.")
        }

        /// `title` and `composer` stay authoritative for the two keys they mirror, so a host reading
        /// either surface sees the same string.
        @Test
        func titleAndComposerMirrorTheirTags() {
            var score = Score(division: 480, parts: [])
            score.metaTags = ["workTitle": "Etude", "composer": "C. Composer"]
            let wire = ScoreMetadataWire(score: score)
            #expect(wire.title == "Etude")
            #expect(wire.composer == "C. Composer")
            #expect(wire.metaTags.first { $0.key == "workTitle" }?.value == "Etude")
        }

        /// A score with no tags at all still encodes — the empty strings are what the two-field shape
        /// always returned for a missing tag, and nothing downstream distinguishes absent from empty.
        @Test
        func scoreWithoutTagsProducesEmptyStrings() {
            let wire = ScoreMetadataWire(score: Score(division: 480, parts: []))
            #expect(wire.title.isEmpty)
            #expect(wire.composer.isEmpty)
            #expect(wire.metaTags.isEmpty)
        }
    }
#endif
