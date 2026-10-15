@testable import SheetMusicCore
import Testing

/// The tokens, defaults and edit rules of an annotated staff text.
@Suite("Staff text annotations")
struct StaffTextAnnotationTests {
    private static let allTokens = [
        "natural", "pizzicato", "open", "mute", "tremolo", "detache", "martele", "col_legno", "sul_ponticello",
        "sul_tasto", "vibrato", "legato", "distortion", "overdrive", "harmonics", "jazz_tone", "handbells_swing",
        "handbells_swing_up", "handbells_swing_down", "handbells_echo_1", "handbells_echo_2", "handbells_damp",
        "handbells_lv", "handbells_r",
    ]

    @Test("every MuseScore technique token round-trips; an unknown one is kept verbatim")
    func techniqueTokens() {
        for token in Self.allTokens {
            let technique = PlayingTechnique(mscxToken: token)
            #expect(technique.mscxToken == token, "\(token)")
            if case .other = technique { Issue.record("\(token) decoded as .other") }
        }
        #expect(PlayingTechnique(mscxToken: "undefined") == .other("undefined"))
        #expect(PlayingTechnique(mscxToken: "future_bow") == .other("future_bow"))
        #expect(PlayingTechnique(mscxToken: "future_bow").mscxToken == "future_bow")
        #expect(PlayingTechnique(mscxToken: "pizzicato") == .pizzicato)
    }

    @Test("pedal positions are MuseScore's ordinals, and an unknown one survives")
    func pedalOrdinals() {
        #expect(HarpPedalDiagram.Position(mscxOrdinal: 0) == .flat)
        #expect(HarpPedalDiagram.Position(mscxOrdinal: 1) == .natural)
        #expect(HarpPedalDiagram.Position(mscxOrdinal: 2) == .sharp)
        #expect(HarpPedalDiagram.Position(mscxOrdinal: 3) == .other(3))
        #expect(HarpPedalDiagram.Position.other(3).mscxOrdinal == 3)
        #expect(HarpPedalDiagram.Position.sharp.mscxOrdinal == 2)
        #expect(HarpPedalDiagram().pedals == Array(repeating: .natural, count: 7))
    }

    @Test("an ordinary staff text has no annotation; a harp diagram draws in its own style")
    func styleTypes() {
        var text = StaffText(text: "dolce")
        #expect(text.annotation == nil)
        #expect(text.styleType == .staffText)
        text.annotation = .playTechnique(.pizzicato, playsBack: true)
        #expect(text.styleType == .staffText)
        text.annotation = .harpPedal(HarpPedalDiagram(isDiagram: true))
        #expect(text.styleType == .harpPedalDiagram)
        text.annotation = .harpPedal(HarpPedalDiagram(isDiagram: false))
        #expect(text.styleType == .harpPedalTextDiagram)
    }

    @Test("SetStaffText leaves an annotation alone: the beat's staff text is a second element")
    func setStaffTextIgnoresAnnotations() throws {
        var pizz = StaffText(text: "pizz.")
        pizz.annotation = .playTechnique(.pizzicato, playsBack: true)
        let address = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        var score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "violin"),
            staves: [Staff(lineCount: 5, measures: [Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 69, tpc: 17)]))),
            ])])])],
        )], systemMeasures: [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .staffText(pizz), originalStaff: address),
        ])])
        let anchor = VoiceElementID(staff: address, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
        #expect(SetStaffText.current(at: anchor, isSystemText: false, in: score) == nil)
        _ = try SetStaffText(anchor: anchor, text: "mute", isSystemText: false).apply(to: &score)
        let texts = score.systemMeasures[0].elements.compactMap { positioned -> StaffText? in
            if case let .staffText(text) = positioned.element { text } else { nil }
        }
        #expect(texts.map(\.text) == ["pizz.", "mute"])
        #expect(texts.map { $0.annotation != nil } == [true, false])
        #expect(SetStaffText.current(at: anchor, isSystemText: false, in: score) == "mute")
    }
}
