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

    /// Round-trip a single Score containing one measure with one
    /// voice plus the supplied positioned system elements. Returns
    /// the re-decoded score so callers can compare its
    /// `systemMeasures` / `voices` field-by-field.
    private func scoreRoundTrip(
        voice: Voice,
        systemElements: [PositionedSystemElement],
    ) throws -> Score {
        let measure = Measure(voices: [voice])
        let part = Part(
            id: "1",
            instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [measure])],
        )
        let score = Score(
            division: 480,
            parts: [part],
            systemMeasures: [SystemMeasure(elements: systemElements)],
        )
        let bytes = try MSCXEncoder.encode(score)
        return try MSCXParser.parse(bytes)
    }

    @Test("Tempo with default TextProperties round-trips")
    func tempoDefaultRoundTrip() throws {
        let voice = Voice(elements: [
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
        ])
        let tempo = Tempo(beatsPerSecond: 2.0)
        let positioned = PositionedSystemElement(
            position: .start,
            element: .tempo(tempo),
        )
        let decoded = try scoreRoundTrip(
            voice: voice, systemElements: [positioned],
        )
        guard let first = decoded.systemMeasures.first?.elements.first,
              case let .tempo(t) = first.element
        else {
            Issue.record("expected a lifted tempo in systemMeasures")
            return
        }
        #expect(t.beatsPerSecond == 2.0)
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

    @Test("StaffText round-trips text, offset, color, visibility")
    func staffTextRoundTrip() throws {
        let staffText = StaffText(
            text: "rit.",
            offsetX: 1.0,
            offsetY: -0.5,
            color: ScoreColor(red: 200, green: 0, blue: 0, alpha: 200),
            isSystemText: false,
            properties: TextProperties(face: "Edwin", size: 10),
            visible: false,
        )
        let positioned = PositionedSystemElement(
            position: .start, element: .staffText(staffText),
        )
        let decoded = try scoreRoundTrip(
            voice: Voice(elements: []), systemElements: [positioned],
        )
        guard let first = decoded.systemMeasures.first?.elements.first,
              case let .staffText(reparsed) = first.element
        else {
            Issue.record("expected lifted .staffText")
            return
        }
        #expect(reparsed == staffText)
    }

    @Test("SystemText round-trips through <SystemText>")
    func systemTextRoundTrip() throws {
        let systemText = StaffText(
            text: "Allegro",
            isSystemText: true,
        )
        let positioned = PositionedSystemElement(
            position: .start, element: .staffText(systemText),
        )
        let decoded = try scoreRoundTrip(
            voice: Voice(elements: []), systemElements: [positioned],
        )
        guard let first = decoded.systemMeasures.first?.elements.first,
              case let .staffText(reparsed) = first.element
        else {
            Issue.record("expected lifted .staffText")
            return
        }
        #expect(reparsed == systemText)
    }

    @Test("RehearsalMark round-trips text, frame, offset, color")
    func rehearsalMarkRoundTrip() throws {
        let mark = RehearsalMark(
            text: "A",
            offsetX: 0.5,
            offsetY: -1.0,
            color: ScoreColor(red: 0, green: 0, blue: 200),
            frame: TextFrameType.circle,
            properties: TextProperties(face: "Edwin", size: 12, style: [.bold]),
        )
        let positioned = PositionedSystemElement(
            position: .start, element: .rehearsalMark(mark),
        )
        let decoded = try scoreRoundTrip(
            voice: Voice(elements: []), systemElements: [positioned],
        )
        guard let first = decoded.systemMeasures.first?.elements.first,
              case let .rehearsalMark(reparsed) = first.element
        else {
            Issue.record("expected lifted .rehearsalMark")
            return
        }
        #expect(reparsed == mark)
    }

    @Test("RehearsalMark default rectangle frame round-trips")
    func rehearsalMarkDefaultFrameRoundTrip() throws {
        let mark = RehearsalMark(text: "B")
        let positioned = PositionedSystemElement(
            position: .start, element: .rehearsalMark(mark),
        )
        let decoded = try scoreRoundTrip(
            voice: Voice(elements: []), systemElements: [positioned],
        )
        guard let first = decoded.systemMeasures.first?.elements.first,
              case let .rehearsalMark(reparsed) = first.element
        else {
            Issue.record("expected lifted .rehearsalMark")
            return
        }
        #expect(reparsed.frame == TextFrameType.rectangle)
        #expect(reparsed.text == "B")
    }

    @Test("RehearsalMark omits <frameType> for the default rectangle frame")
    func rehearsalMarkOmitsDefaultFrameType() throws {
        // Regression: we used to force-write `props.frameType = frame`
        // and emit `<frameType>0</frameType>` for every RehearsalMark.
        // Combined with a stale enum mapping (0/1/2 vs MuseScore's
        // NO_FRAME=0, SQUARE=1, CIRCLE=2), that produced
        // `<frameType>0</frameType>` for rectangle marks — which
        // MuseScore reads as NO_FRAME, dropping the visible border.
        // MuseScore Studio omits `<frameType>` entirely when the
        // value matches the style default; do the same so output
        // matches the original file byte-pattern.
        let mark = RehearsalMark(text: "A")
        let positioned = PositionedSystemElement(
            position: .start, element: .rehearsalMark(mark),
        )
        let measure = Measure(voices: [Voice(elements: [])])
        let part = Part(
            id: "1",
            instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [measure])],
        )
        let score = Score(
            division: 480,
            parts: [part],
            systemMeasures: [SystemMeasure(elements: [positioned])],
        )
        let bytes = try MSCXEncoder.encode(score)
        let text = try #require(String(bytes: bytes, encoding: .utf8))
        #expect(!text.contains("<frameType>"))
    }

    @Test("RehearsalMark with non-default frame uses MuseScore integer mapping")
    func rehearsalMarkExplicitFrameUsesMuseScoreInteger() throws {
        // Verify the encoded integer matches MuseScore upstream
        // (engraving/dom/textbase.h: NO_FRAME=0, SQUARE=1, CIRCLE=2).
        for (frame, expected) in [
            (TextFrameType.circle, "<frameType>2</frameType>"),
            (TextFrameType.none, "<frameType>0</frameType>"),
        ] {
            let mark = RehearsalMark(text: "M", frame: frame)
            let positioned = PositionedSystemElement(
                position: .start, element: .rehearsalMark(mark),
            )
            let measure = Measure(voices: [Voice(elements: [])])
            let part = Part(
                id: "1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [measure])],
            )
            let score = Score(
                division: 480,
                parts: [part],
                systemMeasures: [SystemMeasure(elements: [positioned])],
            )
            let bytes = try MSCXEncoder.encode(score)
            let text = try #require(String(bytes: bytes, encoding: .utf8))
            #expect(text.contains(expected), "expected \(expected) for \(frame)")
        }
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
            visible: false,
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
            // Decoder now emits `.measure` for all measure-typed repeats;
            // use `.measure` here so the decoded value matches the input.
            let mr = MeasureRepeat(numMeasures: num, duration: .measure)
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
                    notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
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

    @Test("mid-measure system element interleaves at chord boundary without <location>")
    func midMeasureSystemElementInterleaves() throws {
        // Regression: a mid-measure lifted StaffText (e.g. position
        // 3/4 inside a 4/4 measure) used to be dumped at the voice
        // head with a forward `<location>3/4</location>` and no
        // matching back-shift. MuseScore reads `<location>` as a
        // cumulative cursor move, so every chord after the head was
        // offset and the bar failed length validation (MS3:
        // "予想: 4/4; 判定: 7/4"). The encoder now interleaves
        // system elements at their natural cursor — no shift needed
        // when the position lands on a chord boundary.
        let voice = Voice(elements: [
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 62, tpc: 16)]))),
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 64, tpc: 18)]))),
            .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 65, tpc: 13)]))),
        ])
        let staffText = StaffText(text: "cresc.")
        let positioned = PositionedSystemElement(
            position: MeasurePosition(numerator: 3, denominator: 4),
            element: .staffText(staffText),
        )

        let measure = Measure(voices: [voice])
        let part = Part(
            id: "1",
            instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [measure])],
        )
        let score = Score(
            division: 480,
            parts: [part],
            systemMeasures: [SystemMeasure(elements: [positioned])],
        )
        let bytes = try MSCXEncoder.encode(score)
        let encodedText = try #require(String(bytes: bytes, encoding: .utf8))

        // No free-standing <location> — StaffText sits inline at the
        // boundary, document order matches MuseScore Studio output.
        #expect(!encodedText.contains("<location>"))
        // The StaffText appears between the 3rd Chord (which ends at
        // 3/4) and the 4th Chord (which starts at 3/4).
        let staffTextRange = try #require(encodedText.range(of: "<StaffText>"))
        let chordRanges = encodedText.ranges(of: "<Chord>")
        #expect(chordRanges.count == 4, "expected 4 chord opens, got \(chordRanges.count)")
        if chordRanges.count >= 4 {
            #expect(chordRanges[2].upperBound < staffTextRange.lowerBound)
            #expect(staffTextRange.upperBound < chordRanges[3].lowerBound)
        }

        // Decoded round-trip preserves the voice exactly (no extra
        // .locationShift elements introduced).
        let reparsed = try MSCXParser.parse(bytes)
        let reVoice = try #require(
            reparsed.parts.first?.staves.first?.measures.first?.voices.first,
        )
        #expect(reVoice == voice)
        let reSysElements = try #require(
            reparsed.systemMeasures.first?.elements,
        )
        #expect(reSysElements.count == 1)
        #expect(reSysElements.first?.position == positioned.position)
    }

    @Test("locationShift round-trips when no system element follows")
    func locationShiftRoundTrip() throws {
        // System elements no longer ride on the voice cursor — those
        // are stored on `SystemMeasure` with explicit positions. A
        // locationShift followed by a chord/dynamic in voice still
        // round-trips, but a shift dangling at end-of-voice with no
        // following voice element is dropped (the decoder treats it
        // as a no-op once the voice ends).
        for delta in [
            Fraction(numerator: 1, denominator: 4),
            Fraction(numerator: -3, denominator: 8),
        ] {
            let voice = Voice(elements: [
                .chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
                .locationShift(delta: delta),
                .dynamic(Dynamic(subtype: "mf", velocity: 80)),
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
            properties: TextProperties(face: "Edwin", size: 11, style: [.italic]),
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
                framePadding: 0.5,
            ),
            visible: false,
        )
        let positioned = PositionedSystemElement(
            position: .start, element: .tempo(tempo),
        )
        let decoded = try scoreRoundTrip(
            voice: Voice(elements: []), systemElements: [positioned],
        )
        guard let first = decoded.systemMeasures.first?.elements.first,
              case let .tempo(reparsed) = first.element
        else {
            Issue.record("expected lifted .tempo")
            return
        }
        #expect(reparsed == tempo)
    }
}
