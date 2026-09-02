@testable import SheetMusicCore
import SheetMusicEditWire
import Testing
import Wirelet

/// Round trips, discriminator pins and hand-mutated-wire refusals for the mark payloads (intents 41…49,
/// edit-command parity group 3, spec 2026-09-02). Its own file, like `EditIntentCodecRangeTests`, because
/// `EditIntentCodecTests.swift` is past SwiftLint's 400-line budget already.
@Suite("EditIntentCodec — mark payloads")
struct EditIntentCodecMarkTests {
    private static let staff = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    private static let slot = VoiceElementID(staff: staff, measureIndex: 2, voiceIndex: 1, elementIndex: 3)
    private static let measure = MeasureRef(measureIndex: 3)

    /// Both shapes of every optional, a non-integer bps and pause, a caesura style, two jumps and two markers —
    /// so a dropped flag, a truncated double or a mis-tagged list element cannot survive looking right.
    private static let cases: [EditIntent] = [
        .setClef(before: slot, clef: .bass8vb),
        .removeClef(at: slot),
        .setTempo(anchor: slot, marking: SetTempo.Marking(beatsPerSecond: 1.24667, beatNote: .eighth, beatDots: 1)),
        .setTempo(anchor: slot, marking: nil),
        .setStaffText(anchor: slot, text: "pizz. を", isSystemText: false),
        .setStaffText(anchor: slot, text: nil, isSystemText: true),
        .setDynamic(at: slot, subtype: "sfz"),
        .setDynamic(at: slot, subtype: nil),
        .setFermata(at: slot, subtype: "fermataLongBelow", timeStretch: 2.75),
        .setFermata(at: slot, subtype: nil, timeStretch: 0),
        .setBreath(after: slot, kind: .caesura(.curved), pause: 0.625),
        .setBreath(after: slot, kind: .breathMark(.salzedo), pause: 0),
        .setBreath(after: slot, kind: nil, pause: 0),
        .setJumps(at: measure, jumps: [
            Jump(jumpTo: "segno", playUntil: "coda", continueAt: "codab", playRepeats: true, text: "D.S. al Coda"),
            Jump(jumpTo: "start", playUntil: "end", text: "D.C."),
        ]),
        .setJumps(at: measure, jumps: []),
        .setMarkers(at: measure, markers: [
            Marker(kind: .segno, label: "segno", text: "<sym>segno</sym>"), Marker(kind: .toCoda, label: "coda"),
        ]),
        .setMarkers(at: measure, markers: []),
    ]

    @Test("every mark intent survives an encode/decode round trip", arguments: cases)
    func roundTrips(intent: EditIntent) throws {
        #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
    }

    /// The `bytes[1]` framing assumption `EditIntentCodecTests` states: every payload here stays under 128 bytes
    /// at these small indices — the list payloads are read with EMPTY lists for exactly that reason, which also
    /// pins the empty-array framing.
    @Test func `the wire discriminators stay where they were`() {
        let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let slot = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
        let measure = MeasureRef(measureIndex: 0)
        #expect(EditIntentCodec.encode(.setClef(before: slot, clef: .treble))[1] == 41)
        #expect(EditIntentCodec.encode(.removeClef(at: slot))[1] == 42)
        #expect(EditIntentCodec.encode(.setTempo(anchor: slot, marking: nil))[1] == 43)
        #expect(EditIntentCodec.encode(.setStaffText(anchor: slot, text: nil, isSystemText: false))[1] == 44)
        #expect(EditIntentCodec.encode(.setDynamic(at: slot, subtype: nil))[1] == 45)
        #expect(EditIntentCodec.encode(.setFermata(at: slot, subtype: nil, timeStretch: 0))[1] == 46)
        #expect(EditIntentCodec.encode(.setBreath(after: slot, kind: nil, pause: 0))[1] == 47)
        #expect(EditIntentCodec.encode(.setJumps(at: measure, jumps: []))[1] == 48)
        #expect(EditIntentCodec.encode(.setMarkers(at: measure, markers: []))[1] == 49)
        #expect(EditIntentCodec.encode(.setTempo(anchor: slot, marking: nil)).count < 128)
    }

    /// `SetBreathIntentWire`'s two style tables are hand-written arrays of four, and its encoder maps a style the
    /// table does not carry to index 0 (`?? 0`) — a new enum case would silently go out as `.comma` / `.normal`.
    /// The counts pin the tables' size against `CaseIterable`; the round trip pins their contents, so adding a
    /// case fails here rather than in a host's file.
    @Test func `every breath style is carried by the wire tables`() throws {
        #expect(Breath.BreathMarkStyle.allCases.count == 4)
        #expect(Breath.CaesuraStyle.allCases.count == 4)
        for style in Breath.BreathMarkStyle.allCases {
            let intent = EditIntent.setBreath(after: Self.slot, kind: .breathMark(style), pause: 0.25)
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
        for style in Breath.CaesuraStyle.allCases {
            let intent = EditIntent.setBreath(after: Self.slot, kind: .caesura(style), pause: 0.25)
            #expect(try EditIntentCodec.decode(EditIntentCodec.encode(intent)) == intent)
        }
    }

    /// A clef spelling `NotatedClef` does not emit must fail the decode, not collapse to treble the way
    /// `NotatedClef(rawType:)` does for a legacy alias.
    @Test func `an unknown clef spelling is refused`() {
        var wire = SetClefIntentWire(target: Self.slot, clef: .bass)
        wire.clefType = "treble"
        let bytes = EditIntentWire.setClef(wire).encodeToData()
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(0)) { try EditIntentCodec.decode(bytes) }
    }

    @Test func `a breath kind or style outside the tables is refused`() {
        var kind = SetBreathIntentWire(location: Self.slot, kind: .breathMark(.comma), pause: 0)
        kind.kind = 2
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.setBreath(kind).encodeToData())
        }
        var style = SetBreathIntentWire(location: Self.slot, kind: .caesura(.short), pause: 0)
        style.style = 4
        #expect(throws: (any Error).self) {
            try EditIntentCodec.decode(EditIntentWire.setBreath(style).encodeToData())
        }
    }

    @Test func `an unknown marker kind inside a list is refused`() {
        var wire = SetMarkersIntentWire(measure: Self.measure, markers: [Marker(kind: .coda, label: "codab")])
        wire.markers[0].kind = "tocoda"
        let bytes = EditIntentWire.setMarkers(wire).encodeToData()
        #expect(throws: WireFormatError.unknownChoiceDiscriminator(0)) { try EditIntentCodec.decode(bytes) }
    }
}
