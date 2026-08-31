import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// Encoding of `<Spanner type="GuitarBend">` — the mirror of
/// `GuitarBendDecodeTests`.
///
/// Whole-`Score` equality against the *original* parse is deliberately not the
/// gate here. The encoder drops an implicit C-major `<KeySig>` at the head of a
/// staff to match MuseScore Studio's writer (`MSCXEncoder+Measure.swift:26`),
/// and `guitarbend_prebend.mscx:121-124` has exactly that, so a single-pass
/// comparison can never be equal there for reasons unrelated to bends. The two
/// properties that *are* meaningful are checked instead, for all six fixtures:
///
/// * **second-pass stability** — the encoder reaches a fixed point after one
///   pass, so nothing it emits decays on re-encode; and
/// * **bend survival** — every note's `(guitarBend, guitarBendBack, fret,
///   string)` is unchanged by the first pass, which is the whole of what the
///   model holds about a bend.
@Suite("GuitarBend round-trip")
struct GuitarBendRoundTripTests {
    static let fixtures = [
        "guitarbend_simple", "guitarbend_prebend", "guitarbend_slightbend",
        "guitarbend_gracebend", "guitarbend_release_twice", "guitarbend_tied",
    ]

    @Test("all bend fixtures survive parse → encode → parse", arguments: fixtures)
    func roundTrip(fixture: String) throws {
        let original = try MSCXParser.parse(MSCXFixtureLoader.mscxData(fixture))
        let first = try MSCXParser.parse(MSCXEncoder.encode(original))
        let second = try MSCXParser.parse(MSCXEncoder.encode(first))

        #expect(first.withSource(.unknown) == second.withSource(.unknown))

        let expected = Self.bendSignature(of: original)
        // Guard against passing vacuously if the walk ever stops finding bends.
        #expect(expected.contains { $0.bend != nil })
        #expect(expected.contains { $0.bendBack })
        #expect(Self.bendSignature(of: first) == expected)
    }

    @Test("encoded begin side carries payload, next location, and anchor 3")
    func encodedShape() throws {
        let text = try Self.encodedText(of: "guitarbend_simple")
        #expect(text.contains(#"<Spanner type="GuitarBend">"#))
        #expect(text.contains("<guitarBendType>0</guitarBendType>"))
        #expect(text.contains("<anchor>3</anchor>"))
        // End-side placeholder re-emitted. The serializer may write the
        // empty element as `<prev>` + `</prev>` or self-closing `<prev/>`,
        // so match without the closing bracket.
        #expect(text.contains("<prev"))
    }

    /// The `<location>` payloads MuseScore Studio itself wrote for
    /// `guitarbend_simple` — the only fixture whose bends are all plain
    /// chord-to-chord, so the expected shape is unambiguous. Pins that the
    /// begin side names the following chord and the end side names the
    /// preceding one, rather than emitting a location-less placeholder that
    /// Studio would silently drop on reload (see `TieLocation.graceZeroDelta`).
    @Test("plain bends carry the neighbour-chord delta on both sides")
    func neighbourChordLocations() throws {
        let text = try Self.encodedText(of: "guitarbend_simple")
        #expect(text.contains("<fractions>1/16</fractions>"))
        #expect(text.contains("<fractions>-1/16</fractions>"))
    }

    /// A slight bend begins and ends on the same note, so both sides carry the
    /// zero-delta location MuseScore writes as an empty `<location>`.
    /// C++: `Score::addGuitarBend` (`editing/cmd.cpp:1009-1014`) sets
    /// `startElement == endElement` for `SLIGHT_BEND` / `DIP` / `SCOOP`.
    @Test("a slight bend emits an empty location on both sides")
    func slightBendLocations() throws {
        let text = try Self.encodedText(of: "guitarbend_slightbend")
        #expect(text.contains("<guitarBendType>3</guitarBendType>"))
        // Neither side may name a neighbouring chord.
        #expect(!text.contains("<fractions>1/16</fractions>"))
        #expect(!text.contains("<fractions>-1/16</fractions>"))
    }

    /// A bend whose partner is a grace chord of the same parent is addressed by
    /// `<grace>`, MuseScore's `Location::graceIndex`. `guitarbend_gracebend`'s
    /// principal notes are ended by their own `<appoggiatura/>`, which the
    /// fixture writes as `<grace>0</grace>` (`:185`, `:239`, `:308`).
    @Test("a grace-note bend addresses its partner by grace ordinal")
    func graceOrdinalLocations() throws {
        let text = try Self.encodedText(of: "guitarbend_gracebend")
        #expect(text.contains("<grace>0</grace>"))
    }

    /// `guitarbend_release_twice` chains bends through two `<grace8after/>`
    /// chords of one parent, which is the only fixture reaching `<grace>1`
    /// (`:158`, `:217`) — the second-sounding after-grace, whose file ordinal
    /// is 1 because an after-grace run is written back-to-front.
    @Test("chained after-grace bends reach the second grace ordinal")
    func afterGraceChainLocations() throws {
        let text = try Self.encodedText(of: "guitarbend_release_twice")
        #expect(text.contains("<grace>0</grace>"))
        #expect(text.contains("<grace>1</grace>"))
        // The end side of the bend that leaves the first parent's after-grace
        // needs *both* halves: the delta names the previous chord, `<grace>`
        // picks the grace within its run (`guitarbend_release_twice.mscx:222-227`).
        #expect(text.contains("<fractions>-1/4</fractions>"))
    }

    // MARK: - Helpers

    /// Parse a fixture, re-encode it, and hand back the XML as text.
    private static func encodedText(of fixture: String) throws -> String {
        let original = try MSCXParser.parse(MSCXFixtureLoader.mscxData(fixture))
        let bytes = try MSCXEncoder.encode(original)
        return try #require(String(bytes: bytes, encoding: .utf8))
    }

    /// Everything the model holds about one note's bend, plus the tablature
    /// position a bend is meaningless without.
    private struct BendSignature: Equatable {
        var bend: GuitarBend?
        var bendBack: Bool
        var fret: Int?
        var string: Int?
    }

    /// Both grace lists are walked: `guitarbend_gracebend` hangs its bends off
    /// `graceNotesBefore` and `guitarbend_release_twice` off `graceNotesAfter`,
    /// so a walk missing either would pass vacuously on half the fixtures.
    private static func bendSignature(of score: Score) -> [BendSignature] {
        score.allStaves.flatMap { _, staff in
            staff.measures.flatMap { measure in
                measure.voices.flatMap { voice in
                    voice.elements.flatMap { element -> [BendSignature] in
                        guard case let .chord(chord) = element else { return [] }
                        let notes = chord.graceNotesBefore.flatMap(\.notes)
                            + chord.notes
                            + chord.graceNotesAfter.flatMap(\.notes)
                        return notes.map {
                            BendSignature(
                                bend: $0.guitarBend,
                                bendBack: $0.guitarBendBack,
                                fret: $0.fret,
                                string: $0.string,
                            )
                        }
                    }
                }
            }
        }
    }
}
