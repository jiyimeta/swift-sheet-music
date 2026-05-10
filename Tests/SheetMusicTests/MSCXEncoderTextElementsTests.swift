import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Round-trip coverage for the `VoiceElement` cases that Phase 2.3
/// promoted from the `throws "not yet supported"` branch into
/// first-class encoders: tempo, dynamic, barLine, staffText / system
/// text, rehearsal mark, harmony, measure repeat, fermata, and the
/// voice-level location shift.
@Suite("MSCXEncoder text-elements")
struct MSCXEncoderTextElementsTests {
    private func voiceRoundTrip(_ voice: Voice) throws -> Voice {
        let xml = try voice.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        let reparsed = try XMLTreeParser.parse(bytes)
        return try Voice.decode(#require(reparsed.first("voice")))
    }

    private func voiceRoundTripXMLString(_ voice: Voice) throws -> String {
        let xml = try voice.encode()
        let bytes = XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [xml]))
        return String(bytes: bytes, encoding: .utf8) ?? ""
    }

    @Test("Tempo with default TextProperties round-trips")
    func tempoDefaultRoundTrip() throws {
        let voice = Voice(elements: [
            .tempo(Tempo(beatsPerSecond: 2.0)),
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
        ])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("BarLine round-trips with and without subtype")
    func barLineRoundTrip() throws {
        for subtype in [nil, "end", "double", "start-repeat"] as [String?] {
            let voice = Voice(elements: [
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
                .barLine(BarLine(subtype: subtype)),
            ])
            let decoded = try voiceRoundTrip(voice)
            #expect(decoded == voice, "BarLine subtype=\(subtype ?? "nil") failed")
        }
    }

    @Test("StaffText round-trips text, offset, colour, visibility")
    func staffTextRoundTrip() throws {
        let staffText = StaffText(
            text: "rit.",
            offsetX: 1.0,
            offsetY: -0.5,
            color: ScoreColor(red: 200, green: 0, blue: 0, alpha: 200),
            isSystemText: false,
            properties: TextProperties(face: "Edwin", size: 10),
            visible: false
        )
        let voice = Voice(elements: [.staffText(staffText)])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("SystemText round-trips through <SystemText>")
    func systemTextRoundTrip() throws {
        let systemText = StaffText(
            text: "Allegro",
            isSystemText: true
        )
        let voice = Voice(elements: [.staffText(systemText)])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("RehearsalMark round-trips text, frame, offset, colour")
    func rehearsalMarkRoundTrip() throws {
        let mark = RehearsalMark(
            text: "A",
            offsetX: 0.5,
            offsetY: -1.0,
            color: ScoreColor(red: 0, green: 0, blue: 200),
            frame: .circle,
            properties: TextProperties(face: "Edwin", size: 12, style: [.bold])
        )
        let voice = Voice(elements: [.rehearsalMark(mark)])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("RehearsalMark default rectangle frame round-trips")
    func rehearsalMarkDefaultFrameRoundTrip() throws {
        let mark = RehearsalMark(text: "B")
        let voice = Voice(elements: [.rehearsalMark(mark)])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("Harmony round-trips standard chord with root/bass/parens")
    func harmonyStandardRoundTrip() throws {
        let harmony = Harmony(
            name: "Cmaj7",
            harmonyType: .standard,
            rootTpc: 14,
            rootCase: .upper,
            bassTpc: 7,
            bassCase: .lower,
            leftParen: true,
            rightParen: true,
            play: false,
            offsetX: 0.5,
            offsetY: -0.25,
            color: ScoreColor(red: 100, green: 100, blue: 100),
            properties: TextProperties(face: "Edwin", size: 11),
            visible: false
        )
        let voice = Voice(elements: [.harmony(harmony)])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("Harmony round-trips Roman and Nashville types")
    func harmonyTypeVariantsRoundTrip() throws {
        for type in [HarmonyType.roman, .nashville] as [HarmonyType] {
            let harmony = Harmony(name: "I", harmonyType: type)
            let voice = Voice(elements: [.harmony(harmony)])
            let decoded = try voiceRoundTrip(voice)
            #expect(decoded == voice, "harmonyType \(type) failed")
        }
    }

    @Test("MeasureRepeat round-trips numMeasures and duration")
    func measureRepeatRoundTrip() throws {
        for num in [1, 2, 4] {
            let mr = MeasureRepeat(
                numMeasures: num,
                duration: .fraction(.init(numerator: 4, denominator: 4))
            )
            let voice = Voice(elements: [.measureRepeat(mr)])
            let decoded = try voiceRoundTrip(voice)
            #expect(decoded == voice, "numMeasures=\(num) failed")
        }
    }

    @Test("Fermata round-trips subtype and explicit timeStretch")
    func fermataRoundTrip() throws {
        // (subtype, explicit timeStretch or nil → use default,
        //  expectedXMLContainsTimeStretch)
        let cases: [(String, Double?, Bool)] = [
            ("fermataAbove", nil, false), // default 1.5 → omit
            ("fermataLongAbove", nil, false), // default 2.0 → omit
            ("fermataAbove", 2.5, true), // override → emit
            ("fermataLongAbove", 2.0, false), // matches default → omit
            ("fermataAbove", 1.0, true), // override to 1.0 → emit
        ]
        for (subtype, stretch, expectXML) in cases {
            let voice = Voice(elements: [
                .chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: 60, tpc: 14)])
                )),
                .fermata(Fermata(subtype: subtype, timeStretch: stretch)),
            ])
            let encoded = try voiceRoundTripXMLString(voice)
            let hasTimeStretch = encoded.contains("<timeStretch>")
            let tag = "subtype=\(subtype) stretch=\(String(describing: stretch))"
            #expect(hasTimeStretch == expectXML, "\(tag) expectedTimeStretchEmitted=\(expectXML)")
            let decoded = try voiceRoundTrip(voice)
            #expect(decoded == voice, "\(tag) failed round-trip")
        }
    }

    @Test("locationShift round-trips positive and negative deltas")
    func locationShiftRoundTrip() throws {
        for delta in [
            Fraction(numerator: 1, denominator: 4),
            Fraction(numerator: -3, denominator: 8),
        ] {
            let voice = Voice(elements: [
                .locationShift(delta: delta),
                .staffText(StaffText(text: "swing")),
            ])
            let decoded = try voiceRoundTrip(voice)
            #expect(decoded == voice, "locationShift \(delta) failed")
        }
    }

    @Test("Dynamic round-trips subtype + velocity + TextProperties")
    func dynamicRoundTrip() throws {
        let dynamic = Dynamic(
            subtype: "ff",
            velocity: 110,
            properties: TextProperties(face: "Edwin", size: 11, style: [.italic])
        )
        let voice = Voice(elements: [.dynamic(dynamic)])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }

    @Test("Tempo round-trips offset, hidden flag, and TextProperties")
    func tempoFullRoundTrip() throws {
        let tempo = Tempo(
            beatsPerSecond: 1.5,
            offsetX: 1.25,
            offsetY: -2.5,
            properties: TextProperties(
                face: "Times New Roman",
                size: 14,
                style: [.bold, .italic],
                frameType: .circle,
                framePadding: 0.5
            ),
            visible: false
        )
        let voice = Voice(elements: [.tempo(tempo)])
        let decoded = try voiceRoundTrip(voice)
        #expect(decoded == voice)
    }
}
