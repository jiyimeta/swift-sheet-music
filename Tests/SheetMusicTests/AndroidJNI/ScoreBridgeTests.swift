#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAndroidJNI
    @testable import SheetMusicBridgeCore
    import Testing

    struct ScoreBridgeTests {
        @Test
        func loadFromMSCXBytesProducesScore() throws {
            let url = try #require(TestResources.url(
                forResource: "midi01",
                withExtension: "mscx",
            ))
            let bytes = try Data(contentsOf: url)
            let score = try ScoreBridge.loadScore(bytes: bytes)
            #expect(!score.parts.isEmpty)
        }

        @Test
        func loadFromMSCZBytesProducesScore() throws {
            let url = try #require(TestResources.url(
                forResource: "midi01",
                withExtension: "mscz",
            ))
            let bytes = try Data(contentsOf: url)
            let score = try ScoreBridge.loadScore(bytes: bytes)
            #expect(!score.parts.isEmpty)
        }

        @Test
        func loadFromMusicXMLBytesProducesScore() throws {
            let url = try #require(TestResources.url(
                forResource: "glissando-wavy",
                withExtension: "musicxml",
            ))
            let bytes = try Data(contentsOf: url)
            let score = try ScoreBridge.loadScore(bytes: bytes)
            #expect(!score.parts.isEmpty)
        }

        /// A Standard MIDI File reaches `MidiImporter` through the same bridge the
        /// Android host calls for every other format. Before the `MThd` case
        /// existed the sniff fell through to `.unknown` and this threw, which is
        /// what the Android host surfaced as "Failed to load the score."
        @Test
        func loadFromStandardMidiFileBytesProducesScore() throws {
            let url = try #require(TestResources.url(
                forResource: "midi01-ref",
                withExtension: "mid",
            ))
            let bytes = try Data(contentsOf: url)
            let score = try ScoreBridge.loadScore(bytes: bytes)
            #expect(!score.parts.isEmpty)
        }

        /// The four magics are mutually exclusive: `MThd` is neither the ZIP magic
        /// nor XML text, so adding it cannot reclassify a file that already loaded.
        @Test
        func sniffSeparatesAllFourFormats() throws {
            func bytes(_ resource: String, _ ext: String) throws -> Data {
                let url = try #require(TestResources.url(
                    forResource: resource, withExtension: ext,
                ))
                return try Data(contentsOf: url)
            }
            #expect(try ScoreBridge.sniff(bytes("midi01", "mscx")) == .mscx)
            #expect(try ScoreBridge.sniff(bytes("midi01", "mscz")) == .mscz)
            #expect(try ScoreBridge.sniff(bytes("glissando-wavy", "musicxml")) == .musicXML)
            #expect(try ScoreBridge.sniff(bytes("midi01-ref", "mid")) == .midi)
            #expect(ScoreBridge.sniff(Data("not a score".utf8)) == .unknown)
        }

        @Test
        func loadFromGarbageThrows() {
            #expect(throws: Error.self) {
                _ = try ScoreBridge.loadScore(bytes: Data("not a score".utf8))
            }
        }
    }
#endif
