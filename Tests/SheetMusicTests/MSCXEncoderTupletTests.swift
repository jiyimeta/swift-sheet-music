import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder tuplets")
struct MSCXEncoderTupletTests {
    @Test("Triplet of quarters round-trips through Voice.decode")
    func tripletRoundTrip() throws {
        // A triplet (2:3) of three quarter notes occupies the time of
        // two quarters. Each member's stored duration is quarter*2/3 = 1/6.
        let scaledQuarter = NoteDuration.fraction(.init(numerator: 1, denominator: 6))
        let voice = Voice(
            elements: [
                .chord(Chord(duration: scaledQuarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
                .chord(Chord(duration: scaledQuarter, notes: ChordNotes([Note(pitch: 62, tpc: 16)]))),
                .chord(Chord(duration: scaledQuarter, notes: ChordNotes([Note(pitch: 64, tpc: 18)]))),
            ],
            tuplets: [
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2),
            ]
        )

        let xml = try voice.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        let voiceNode = try #require(reparsed.first("voice"))
        let decoded = try Voice.decode(voiceNode)
        #expect(decoded == voice)
    }

    @Test("Nested triplet-in-triplet (shared bounds) round-trips through Voice.decode")
    func nestedTripletsSharedBoundsRoundTrip() throws {
        // Inner triplet of three eighths inside an outer triplet that
        // covers the same three members. Each chord's stored duration
        // is eighth × 2/3 × 2/3 = 1/8 × 4/9 = 1/18.
        let scaled = NoteDuration.fraction(.init(numerator: 1, denominator: 18))
        let voice = Voice(
            elements: [
                .chord(Chord(duration: scaled, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
                .chord(Chord(duration: scaled, notes: ChordNotes([Note(pitch: 62, tpc: 16)]))),
                .chord(Chord(duration: scaled, notes: ChordNotes([Note(pitch: 64, tpc: 18)]))),
            ],
            tuplets: [
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2),
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2),
            ]
        )
        let xml = try voice.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        let decoded = try Voice.decode(#require(reparsed.first("voice")))
        #expect(decoded == voice)
    }

    @Test("Inner tuplet strictly inside outer tuplet round-trips")
    func nestedTupletStrictInnerRoundTrip() throws {
        // Outer: triplet of quarters [0..3] — each scaled by 2/3.
        // Inner: triplet of quarters [1..2] — those two elements get
        // an additional 2/3 scale, producing quarter × 4/9 = 1/9.
        let outerOnly = NoteDuration.fraction(.init(numerator: 1, denominator: 6))
        let nested = NoteDuration.fraction(.init(numerator: 1, denominator: 9))
        let voice = Voice(
            elements: [
                .chord(Chord(duration: outerOnly, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
                .chord(Chord(duration: nested, notes: ChordNotes([Note(pitch: 62, tpc: 16)]))),
                .chord(Chord(duration: nested, notes: ChordNotes([Note(pitch: 64, tpc: 18)]))),
                .chord(Chord(duration: outerOnly, notes: ChordNotes([Note(pitch: 65, tpc: 13)]))),
            ],
            // Decoder appends tuplets in close-order (inner closes
            // first at index 2, outer at index 3) — match that here
            // so equality holds.
            tuplets: [
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 2),
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 3),
            ]
        )
        let xml = try voice.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        let decoded = try Voice.decode(#require(reparsed.first("voice")))
        #expect(decoded == voice)
    }

    @Test("Overlapping (non-nested) tuplets throw")
    func overlappingTupletsThrow() {
        // [0..2] and [1..3] overlap without full containment — illegal.
        let scaled = NoteDuration.fraction(.init(numerator: 1, denominator: 6))
        let voice = Voice(
            elements: (0 ..< 4).map { i in
                .chord(Chord(
                    duration: scaled,
                    notes: ChordNotes([Note(pitch: 60 + i, tpc: 14)])
                ))
            },
            tuplets: [
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2),
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3),
            ]
        )
        #expect(throws: SheetMusicError.self) {
            try voice.encode()
        }
    }

    /// MuseScore 3's `Tuplet::read` leaves `_baseLen` invalid when
    /// `<baseNote>` is missing, then crashes with SIGFPE in
    /// `Ms::Measure::readVoice` on the first member's tick math.
    /// The encoder must emit `<baseNote>` derived from each member's
    /// unscaled (written) duration. MS4 readers tolerate the field.
    @Test("Tuplet emits <baseNote> matching member's written duration")
    func tupletEmitsBaseNote() throws {
        // Eighth-note triplet (2:3): each chord stored as 1/12.
        let scaledEighth = NoteDuration.fraction(.init(numerator: 1, denominator: 12))
        let voice = Voice(
            elements: [
                .chord(Chord(duration: scaledEighth, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
                .chord(Chord(duration: scaledEighth, notes: ChordNotes([Note(pitch: 62, tpc: 16)]))),
                .chord(Chord(duration: scaledEighth, notes: ChordNotes([Note(pitch: 64, tpc: 18)]))),
            ],
            tuplets: [
                Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2),
            ]
        )
        let xml = try voice.encode()
        let tuplet = try #require(xml.first("Tuplet"))
        #expect(tuplet.first("baseNote")?.text == "eighth")
        // normalNotes/actualNotes preserved.
        #expect(tuplet.first("normalNotes")?.text == "2")
        #expect(tuplet.first("actualNotes")?.text == "3")
    }
}
