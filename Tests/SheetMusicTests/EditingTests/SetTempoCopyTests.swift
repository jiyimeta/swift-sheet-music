@testable import SheetMusicCore
import Testing

/// A copied tempo pastes as the marking that was copied: `SetTempo.marking(copying:)` carries the stored number and
/// beat, the words, `<type>`, `<followText>` and `<play>`, and a write states the type and follow flag over whatever
/// the text edit makes of them — so an "a tempo" pastes as an "a tempo", not as a fixed tempo saying "a tempo".
@Suite("SetTempo — pasting a copied marking")
struct SetTempoCopyTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let first = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)
    private static let second = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2)

    /// Four quarter rests with `tempo` at the first beat, when given.
    private static func score(with tempo: Tempo?, atSecondBeat second: Tempo? = nil) -> Score {
        var score = EditingFixtures.fourQuarterRests()
        var elements: [PositionedSystemElement] = []
        if let tempo {
            elements.append(PositionedSystemElement(position: .start, element: .tempo(tempo)))
        }
        if let second {
            let position = SystemLaneSlot.position(of: Self.second, in: score) ?? .start
            elements.append(PositionedSystemElement(position: position, element: .tempo(second)))
        }
        score.systemMeasures = [SystemMeasure(elements: elements)]
        return score
    }

    @Test("an 'a tempo' pastes as an 'a tempo', its stored number and words kept")
    func aTempoPastesAsATempo() throws {
        let aTempo = Tempo(beatsPerSecond: 1.5, text: "a tempo", followText: true, textType: .aTempo)
        var score = Self.score(with: aTempo)
        let copied = try #require(SetTempo.tempo(at: Self.first, in: score))

        _ = try SetTempo(anchor: Self.second, marking: SetTempo.marking(copying: copied)).apply(to: &score)

        let pasted = try #require(SetTempo.tempo(at: Self.second, in: score))
        #expect(pasted.textType == .aTempo)
        #expect(pasted.followText)
        #expect(pasted.text == "a tempo")
        #expect(pasted.beatsPerSecond == 1.5)
    }

    @Test("a paste over another marking writes the copy's type and follow flag over it")
    func pasteOverwritesTypeAndFollowFlag() throws {
        let allegro = Tempo(beatsPerSecond: 2.4, text: "Allegro", followText: false, playsBack: false)
        let aTempo = Tempo(beatsPerSecond: 1.5, text: "a tempo", followText: true, textType: .aTempo)
        var score = Self.score(with: allegro, atSecondBeat: aTempo)

        _ = try SetTempo(anchor: Self.second, marking: SetTempo.marking(copying: allegro)).apply(to: &score)

        let pasted = try #require(SetTempo.tempo(at: Self.second, in: score))
        #expect(pasted.textType == .normal)
        #expect(!pasted.followText)
        #expect(pasted.text == "Allegro")
        #expect(pasted.beatsPerSecond == 2.4)
        #expect(!pasted.playsBack)
    }

    @Test("a derived marking pastes derived, dropping the words the destination had")
    func derivedPastesDerived() throws {
        let derived = Tempo(beatsPerSecond: 3, beatNote: .quarter, beatDots: 1)
        let allegro = Tempo(beatsPerSecond: 2.4, text: "Allegro")
        var score = Self.score(with: derived, atSecondBeat: allegro)

        _ = try SetTempo(anchor: Self.second, marking: SetTempo.marking(copying: derived)).apply(to: &score)

        let pasted = try #require(SetTempo.tempo(at: Self.second, in: score))
        #expect(pasted.text == nil)
        #expect(pasted.beatDots == 1)
        #expect(pasted.beatsPerSecond == 3)
    }

    @Test("a copy pasted where it already stands plans nothing; anywhere it differs plans the write")
    func restatementPlansNothing() {
        let aTempo = Tempo(beatsPerSecond: 1.5, text: "a tempo", followText: true, textType: .aTempo)
        let score = Self.score(with: aTempo, atSecondBeat: Tempo(beatsPerSecond: 1.5, text: "a tempo"))
        let marking = SetTempo.marking(copying: aTempo)

        #expect(ScoreEditSession.markCommand(for: .setTempo(anchor: Self.first, marking: marking), in: score) == nil)
        #expect(ScoreEditSession.markCommand(for: .setTempo(anchor: Self.second, marking: marking), in: score) != nil)
    }
}
