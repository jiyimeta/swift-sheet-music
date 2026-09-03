@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// Round trips, discriminator pins and hand-mutated-wire refusals for the note / chord payloads (intents 50…57,
/// edit-command parity group 4). Its own file, like `EditIntentCodecMarkTests`, because `EditIntentCodecTests.swift`
/// is past SwiftLint's 400-line budget already.
@Suite("EditIntentCodec — notation payloads")
struct EditIntentCodecNotationTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    private static let slot = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3)
    private static let note = NoteID(
        staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3, noteIndexInChord: 1,
    )

    private static let grace = GraceChord(
        graceType: .acciaccatura, duration: .eighth,
        notes: [Note(pitch: 59, tpc: 13, accidental: .flat), Note(pitch: 62, tpc: 16)],
    )

    /// Both shapes of every optional, a two-element nested list, an unknown articulation token, a non-default
    /// stroke style and a wavy glissando with text — so a dropped flag, a mis-tagged nested list or a swapped
    /// table entry cannot survive looking right.
    private static let cases: [EditIntent] = [
        .setArticulation(at: slot, kind: .staccato, anchor: .below, present: true),
        .setArticulation(at: slot, kind: .marcatoStaccato, anchor: nil, present: false),
        .setArticulation(at: slot, kind: .unknown(subtype: "articSoftAccentAbove"), anchor: .above, present: true),
        .setGraceNotes(at: slot, before: [grace], after: [
            GraceChord(graceType: .grace16after, duration: .sixteenth, notes: [Note(pitch: 67, tpc: 15)]),
        ]),
        .setGraceNotes(at: slot, before: [], after: []),
        .setTremolo(at: slot, tremolo: Tremolo(subtype: .r64, span: .between, strokeStyle: .z)),
        .setTremolo(at: slot, tremolo: nil),
        .setArpeggio(at: slot, subtype: 5),
        .setArpeggio(at: slot, subtype: nil),
        .setGlissando(at: note, glissando: Glissando(
            style: .portamento, visualType: .wavy, easeIn: 30, easeOut: 70, text: "gliss.",
        )),
        .setGlissando(at: note, glissando: Glissando(style: .diatonic, text: nil)),
        .setGlissando(at: note, glissando: nil),
        .setDots(at: slot, dots: 3),
        .setDots(at: slot, dots: 0),
        .setChordLine(at: slot, kind: .scoop, isStraight: true),
        .setChordLine(at: slot, kind: nil, isStraight: false),
        .setNoteParentheses(at: note, parentheses: .both),
        .setNoteParentheses(at: note, parentheses: .none),
    ]

    @Test("every notation intent survives an encode/decode round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    /// The `bytes[1]` framing assumption `EditIntentCodecTests` states: every payload here stays under 128 bytes
    /// at these small indices — `setGraceNotes` is pinned with EMPTY lists for exactly that reason, which also
    /// pins the empty-array framing of the outer list.
    @Test func `the wire discriminators stay where they were`() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let slot = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
        let note = NoteID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0)
        #expect(EditIntentCodec.encode(.setArticulation(at: slot, kind: .tenuto, anchor: nil, present: false))[1] == 50)
        #expect(EditIntentCodec.encode(.setGraceNotes(at: slot, before: [], after: []))[1] == 51)
        #expect(EditIntentCodec.encode(.setTremolo(at: slot, tremolo: nil))[1] == 52)
        #expect(EditIntentCodec.encode(.setArpeggio(at: slot, subtype: nil))[1] == 53)
        #expect(EditIntentCodec.encode(.setGlissando(at: note, glissando: nil))[1] == 54)
        #expect(EditIntentCodec.encode(.setDots(at: slot, dots: 0))[1] == 55)
        #expect(EditIntentCodec.encode(.setChordLine(at: slot, kind: nil, isStraight: false))[1] == 56)
        #expect(EditIntentCodec.encode(.setNoteParentheses(at: note, parentheses: .none))[1] == 57)
        #expect(EditIntentCodec.encode(.setGraceNotes(at: slot, before: [], after: [])).count < 128)
    }

    /// The tremolo tables are three hand-written `u8` maps whose encoders fall back to index 0 for a value the
    /// table lacks. The round trip pins their contents, so a swapped entry fails here rather than in a host's file.
    @Test func `every tremolo shape survives`() throws {
        for bars in [Tremolo.Subtype.r8, .r16, .r32, .r64] {
            for span in [Tremolo.Span.single, .between] {
                for stroke in [Tremolo.StrokeStyle.default, .traditional, .z] {
                    let intent = EditIntent.setTremolo(
                        at: Self.slot, tremolo: Tremolo(subtype: bars, span: span, strokeStyle: stroke),
                    )
                    #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
                }
            }
        }
    }

    @Test func `every glissando style, chord line kind and parenthesis survives`() throws {
        for style in [Glissando.Style.chromatic, .diatonic, .whiteKeys, .blackKeys, .portamento] {
            for visual in [Glissando.VisualType.straight, .wavy] {
                let intent = EditIntent.setGlissando(
                    at: Self.note, glissando: Glissando(style: style, visualType: visual),
                )
                #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
            }
        }
        #expect(ChordLine.Kind.allCases.count == 4)
        for kind in ChordLine.Kind.allCases {
            let intent = EditIntent.setChordLine(at: Self.slot, kind: kind, isStraight: false)
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
        for parens in [NoteParentheses.none, .left, .right, .both] {
            let intent = EditIntent.setNoteParentheses(at: Self.note, parentheses: parens)
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
    }

    /// The nested list: a grace chord holding two notes inside a list holding two chords, plus the shape a chord
    /// with NO notes takes — the inner empty list, which is the framing a flat mirror would get wrong.
    @Test func `the nested grace lists round-trip, including an empty inner list`() throws {
        let empty = GraceChord(graceType: .grace4, duration: .quarter, notes: [])
        let intent = EditIntent.setGraceNotes(
            at: Self.slot, before: [Self.grace, empty], after: [Self.grace],
        )
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    @Test func `values outside the hand-written tables are refused`() {
        var tremolo = SetTremoloIntentWire(location: Self.slot, tremolo: Tremolo(subtype: .r8))
        tremolo.subtype = 5
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.setTremolo(tremolo).encodeToData())
        }
        var arpeggio = SetArpeggioIntentWire(location: Self.slot, subtype: 1)
        arpeggio.subtype = 6
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.setArpeggio(arpeggio).encodeToData())
        }
        var dots = SetDotsIntentWire(location: Self.slot, dots: 1)
        dots.dots = 4
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.setDots(dots).encodeToData())
        }
        var parens = SetNoteParenthesesIntentWire(location: Self.note, parentheses: .both)
        parens.parentheses = 4
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.setNoteParentheses(parens).encodeToData())
        }
        var grace = SetGraceNotesIntentWire(location: Self.slot, before: [Self.grace], after: [])
        grace.before[0].graceType = "quaver"
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(0)) {
            try EditIntentCodec.decode(EditIntentWire.setGraceNotes(grace).encodeToData())
        }
    }

    /// An articulation token the Core table does not know is the deliberate exception to the raw-string rule: it
    /// decodes to `.unknown(subtype:)` rather than throwing, so a mark round-tripped out of a file this package
    /// does not model is still toggleable. Pinned so a later "tighten the decoder" change has to argue with it.
    @Test func `an unknown articulation token decodes to unknown rather than throwing`() throws {
        let intent = EditIntent.setArticulation(
            at: Self.slot, kind: .unknown(subtype: "articLaissezVibrerAbove"), anchor: nil, present: true,
        )
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }
}
