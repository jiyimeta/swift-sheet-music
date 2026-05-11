import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

// MARK: - MSCX round-trip

@Suite("MSCX Swing")
struct MSCXSwingTests {
    @Test("Style swing fields round-trip when set")
    func styleSwingRoundTrip() throws {
        var style = ScoreStyle.museScoreDefaults
        style.swingUnit = .eighth
        style.swingRatio = 67
        let original = Score(division: 480, style: style)

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.style.swingUnit == .eighth)
        #expect(reparsed.style.swingRatio == 67)
    }

    @Test("Style swing defaults skip emission")
    func styleSwingDefaultsElided() throws {
        let style = ScoreStyle.museScoreDefaults
        let original = Score(division: 480, style: style)

        let bytes = try MSCXEncoder.encode(original)
        let xml = String(bytes: bytes, encoding: .utf8) ?? ""

        #expect(!xml.contains("swingUnit"))
        #expect(!xml.contains("swingRatio"))
    }

    @Test("Swing voice element round-trips through MSCX as a SystemText with <swing>")
    func swingElementRoundTrip() throws {
        let swing = Swing(
            text: "Swing",
            unit: .eighth,
            ratio: 60,
            isSystemText: true,
        )
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            defaultClefType: nil,
            measures: [Measure(voices: [Voice(elements: [
                .swing(swing),
                .chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                )),
            ])])],
        )
        let part = Part(
            id: "1",
            trackName: "Voice",
            instrument: Instrument(id: "voice"),
            staves: [staff],
        )
        let original = Score(division: 480, parts: [part])

        let bytes = try MSCXEncoder.encode(original)
        let xmlString = String(bytes: bytes, encoding: .utf8) ?? ""
        // SystemText wrapper plus inline marker child.
        #expect(xmlString.contains("<SystemText>"))
        #expect(xmlString.contains("<swing"))
        #expect(xmlString.contains("unit=\"eighth\""))
        #expect(xmlString.contains("ratio=\"60\""))

        let reparsed = try MSCXParser.parse(bytes)
        let firstVoice = reparsed.parts[0].staves[0].measures[0].voices[0]
        guard case let .swing(decoded) = firstVoice.elements.first else {
            Issue.record("Expected first element to be .swing")
            return
        }
        #expect(decoded.unit == .eighth)
        #expect(decoded.ratio == 60)
        #expect(decoded.isSystemText)
        #expect(decoded.text == "Swing")
    }

    @Test("16th swing unit serialises with the MuseScore '16th' token")
    func sixteenthSwingUnitToken() throws {
        let swing = Swing(unit: .sixteenth, ratio: 75)
        let xml = swing.encode()
        let swingChild = try #require(xml.first("swing"))
        #expect(swingChild.attributes["unit"] == "16th")
        #expect(swingChild.attributes["ratio"] == "75")
    }

    @Test("StaffText without <swing> child still routes to .staffText")
    func plainStaffTextStillStaffText() throws {
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            defaultClefType: nil,
            measures: [Measure(voices: [Voice(elements: [
                .staffText(StaffText(text: "rit.", isSystemText: true)),
                .chord(Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                )),
            ])])],
        )
        let part = Part(
            id: "1",
            trackName: "V",
            instrument: Instrument(id: "voice"),
            staves: [staff],
        )
        let original = Score(division: 480, parts: [part])

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)
        let firstVoice = reparsed.parts[0].staves[0].measures[0].voices[0]

        guard case let .staffText(decoded) = firstVoice.elements.first else {
            Issue.record("Expected .staffText for non-swing SystemText")
            return
        }
        #expect(decoded.text == "rit.")
    }
}

// MARK: - MIDI render

@Suite("MIDI Swing render")
struct MidiSwingRenderTests {
    /// Build a single-staff score with `count` consecutive 8th-note Cs
    /// at a 480 PPQ resolution; assigns the requested swing setting to
    /// the score Style.
    private func eighthNoteRunScore(
        count: Int,
        styleUnit: SwingUnit,
        styleRatio: Int = 60,
    ) -> Score {
        var style = ScoreStyle.museScoreDefaults
        style.swingUnit = styleUnit
        style.swingRatio = styleRatio
        let voice = Voice(elements: (0 ..< count).map { _ in
            .chord(Chord(
                duration: .eighth,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            ))
        })
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            defaultClefType: nil,
            measures: [Measure(voices: [voice])],
        )
        let part = Part(
            id: "1",
            trackName: "V",
            instrument: Instrument(id: "voice"),
            staves: [staff],
        )
        return Score(division: 480, parts: [part], style: style)
    }

    private func noteOnTicks(_ midi: MidiFile) -> [Int] {
        midi.tracks.flatMap { track in
            track.events.compactMap { ev -> Int? in
                if case .noteOn = ev.event { return ev.tick }
                return nil
            }
        }.sorted()
    }

    @Test("Straight 8ths are unswung when style swing is .off")
    func straightEighthsUnchanged() throws {
        let score = eighthNoteRunScore(count: 4, styleUnit: .off)
        let midi = try MidiRenderer.render(score: score)
        // Default 480 PPQ, 8th = 240 ticks: onsets at 0, 240, 480, 720.
        #expect(noteOnTicks(midi) == [0, 240, 480, 720])
    }

    @Test("Eighth swing at ratio 60 shifts up-beats forward by swingBeat * 10/100")
    func eighthSwingShiftsUpbeats() throws {
        // ratio=60 → swingTickAdjust = 480*(60-50)/100 = 48 ticks.
        // Up-beats (240, 720) shift to 240+48, 720+48; down-beats stay.
        let score = eighthNoteRunScore(count: 4, styleUnit: .eighth, styleRatio: 60)
        let midi = try MidiRenderer.render(score: score)
        #expect(noteOnTicks(midi) == [0, 288, 480, 768])
    }

    @Test("Triplet swing (ratio 67) shifts up-beats by 480*17/100 = 81 ticks")
    func tripletSwingShift() throws {
        let score = eighthNoteRunScore(count: 4, styleUnit: .eighth, styleRatio: 67)
        let midi = try MidiRenderer.render(score: score)
        // Up-beats shift by 480*(67-50)/100 = 81 (integer division).
        #expect(noteOnTicks(midi) == [0, 321, 480, 801])
    }

    @Test("Mid-piece Swing directive turns swing on after a straight prelude")
    func midPieceSwingDirective() throws {
        var style = ScoreStyle.museScoreDefaults
        style.swingUnit = .off
        let voice = Voice(elements: [
            // Two straight 8ths.
            .chord(Chord(duration: .eighth, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
            .chord(Chord(duration: .eighth, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
            // Switch to soft swing for the rest.
            .swing(Swing(unit: .eighth, ratio: 60)),
            // Two more 8ths under swing.
            .chord(Chord(duration: .eighth, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
            .chord(Chord(duration: .eighth, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))),
        ])
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            defaultClefType: nil,
            measures: [Measure(voices: [voice])],
        )
        let part = Part(
            id: "1",
            trackName: "V",
            instrument: Instrument(id: "voice"),
            staves: [staff],
        )
        let score = Score(division: 480, parts: [part], style: style)
        let midi = try MidiRenderer.render(score: score)
        // Straight section: 0, 240. Swung section: down-beat at 480
        // stays, up-beat at 720 shifts +48 = 768.
        #expect(noteOnTicks(midi) == [0, 240, 480, 768])
    }

    @Test("Tuplet members are not swung (matches MuseScore's !chord->tuplet())")
    func tupletMembersUnswung() throws {
        var style = ScoreStyle.museScoreDefaults
        style.swingUnit = .eighth
        style.swingRatio = 67
        // Quarter triplet: three quarter-notes occupying 2 quarters.
        // Each member's scaled duration = 1/4 * 2/3 = 1/6 of a whole.
        let triplet = Tuplet(
            normalNotes: 2, actualNotes: 3,
            startIndex: 0, endIndex: 2,
        )
        let scaled: NoteDuration = .fraction(
            Fraction(numerator: 1, denominator: 6),
        )
        let voice = Voice(
            elements: (0 ..< 3).map { _ in
                .chord(Chord(
                    duration: scaled,
                    notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                ))
            },
            tuplets: [triplet],
        )
        let staff = Staff(
            staffType: "stdNormal",
            group: "pitched",
            defaultClefType: nil,
            measures: [Measure(voices: [voice])],
        )
        let part = Part(
            id: "1",
            trackName: "V",
            instrument: Instrument(id: "voice"),
            staves: [staff],
        )
        let score = Score(division: 480, parts: [part], style: style)
        let midi = try MidiRenderer.render(score: score)
        // Triplet quarters at 480 PPQ: each is 320 ticks. Onsets land
        // at 0, 320, 640 — straight, regardless of swing setting.
        #expect(noteOnTicks(midi) == [0, 320, 640])
    }
}

// MARK: - Algorithm unit tests

@Suite("Swing adjustment")
struct SwingAdjustmentTests {
    @Test("Down-beat in pair stays put when next chord is at the swing-unit boundary")
    func downbeatStays() {
        let adj = MidiRenderer.swingAdjustment(
            startTick: 0,
            chordTicks: 240,
            prevChordTicks: nil,
            nextChordTicks: 240,
            isInTuplet: false,
            state: MidiRenderer.SwingState(unitTicks: 240, ratio: 60),
        )
        #expect(adj.onsetShift == 0)
        // Down-beat extension active because endTick (240) lands at
        // the swing-unit position in the pair.
        #expect(adj.lengthDelta == 48)
    }

    @Test("Up-beat in pair shifts forward by swingBeat * (ratio-50) / 100")
    func upbeatShifts() {
        let adj = MidiRenderer.swingAdjustment(
            startTick: 240,
            chordTicks: 240,
            prevChordTicks: 240,
            nextChordTicks: nil,
            isInTuplet: false,
            state: MidiRenderer.SwingState(unitTicks: 240, ratio: 60),
        )
        #expect(adj.onsetShift == 48)
        // Length decreases to compensate.
        #expect(adj.lengthDelta == -48)
    }

    @Test("Subdivided up-beat skips swing")
    func subdividedSkipped() {
        // Previous chord shorter than swingUnit → subdivided.
        let adj = MidiRenderer.swingAdjustment(
            startTick: 240,
            chordTicks: 240,
            prevChordTicks: 120,
            nextChordTicks: nil,
            isInTuplet: false,
            state: MidiRenderer.SwingState(unitTicks: 240, ratio: 60),
        )
        #expect(adj == .none)
    }

    @Test("Tuplet member returns no adjustment")
    func tupletMemberNoAdjust() {
        let adj = MidiRenderer.swingAdjustment(
            startTick: 240,
            chordTicks: 240,
            prevChordTicks: 240,
            nextChordTicks: 240,
            isInTuplet: true,
            state: MidiRenderer.SwingState(unitTicks: 240, ratio: 60),
        )
        #expect(adj == .none)
    }

    @Test("Swing off (unitTicks=0) returns no adjustment regardless of ratio")
    func swingOffNoAdjust() {
        let adj = MidiRenderer.swingAdjustment(
            startTick: 240,
            chordTicks: 240,
            prevChordTicks: 240,
            nextChordTicks: 240,
            isInTuplet: false,
            state: MidiRenderer.SwingState(unitTicks: 0, ratio: 75),
        )
        #expect(adj == .none)
    }
}
