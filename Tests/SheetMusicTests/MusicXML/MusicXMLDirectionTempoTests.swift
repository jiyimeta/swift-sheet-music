import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

@Suite("MusicXML direction tempo")
struct MusicXMLDirectionTempoTests {
    private typealias F = DirectionFixtures
    private typealias Found = (position: MeasurePosition, tempo: Tempo, staff: StaffAddress?)

    private static func tempos(_ score: Score, measure: Int = 0) -> [Found] {
        F.lane(score, measure: measure).compactMap { entry -> Found? in
            guard case let .tempo(tempo) = entry.element else { return nil }
            return (entry.position, tempo, entry.originalStaff)
        }
    }

    private static func staffTextCount(_ score: Score, measure: Int = 0) -> Int {
        F.lane(score, measure: measure).filter { entry in
            if case .staffText = entry.element { return true }
            return false
        }.count
    }

    private static func near(_ value: Double?, _ expected: Double) -> Bool {
        guard let value else { return false }
        return abs(value - expected) < 1e-9
    }

    private static func metronome(_ unit: String, dotted: Bool = false, perMinute: Int) -> String {
        "<metronome><beat-unit>\(unit)</beat-unit>\(dotted ? "<beat-unit-dot/>" : "")"
            + "<per-minute>\(perMinute)</per-minute></metronome>"
    }

    private static func sound(_ tempo: Int) -> String {
        "<sound tempo=\"\(tempo)\"/>"
    }

    @Test("the registry refuses a second tempo on a tick unless the first was MuseScore's default")
    func registry() {
        var registry = MusicXMLTempoRegistry()
        let tick = Fraction(numerator: 1, denominator: 4)
        #expect(registry.canAdd(measure: 0, tick: tick))
        registry.record(measure: 0, tick: tick, beatsPerSecond: 1.5)
        #expect(!registry.canAdd(measure: 0, tick: tick))
        #expect(registry.canAdd(measure: 0, tick: Fraction.zeroTick))
        registry.record(measure: 1, tick: tick, beatsPerSecond: 2.0)
        #expect(registry.canAdd(measure: 1, tick: tick))
    }

    @Test("a metronome and a sound tempo make a visible tempo that stays derived")
    func metronomeAndSound() throws {
        let body = F.direction(Self.metronome("quarter", perMinute: 100), Self.sound(100)) + F.fourQuarters
        let found = try Self.tempos(F.score(measures: [body]))
        #expect(found.count == 1)
        #expect(found.first?.position == MeasurePosition.start)
        #expect(Self.near(found.first?.tempo.beatsPerSecond, 100.0 / 60))
        #expect(found.first?.tempo.text == nil)
        #expect(found.first?.tempo.beatNote == .quarter)
        #expect(found.first?.tempo.followText == true)
        #expect(found.first?.tempo.visible == true)
    }

    @Test("words keep their trailing space in front of the metronome (testTempoTextSpace1_ref.mscx)")
    func trailingSpaceBeforeMetronome() throws {
        let words = F.words("Surreptitiously ", attributes: "font-weight=\"bold\"")
        let body = F.direction(words + Self.metronome("quarter", perMinute: 100), Self.sound(100)) + F.fourQuarters
        let tempo = try Self.tempos(F.score(measures: [body])).first?.tempo
        #expect(tempo?.text?.hasPrefix("Surreptitiously ") == true)
        let xml = tempo?.preservedTextMarkup?.xmlText
        #expect(xml?.hasPrefix("<b>Surreptitiously </b><sym>metNoteQuarterUp</sym>") == true)
    }

    @Test("a dotted metronome keeps its beat while the sound tempo plays")
    func dottedMetronome() throws {
        let body = F.direction(Self.metronome("quarter", dotted: true, perMinute: 80), Self.sound(120)) + F.fourQuarters
        let tempo = try Self.tempos(F.score(measures: [body])).first?.tempo
        #expect(Self.near(tempo?.beatsPerSecond, 2.0))
        #expect(tempo?.beatDots == 1)
        #expect(tempo?.text == nil)
    }

    @Test("a metronome with no sound tempo still plays its own tempo (P2:3490-3492)")
    func metronomeAlone() throws {
        let body = F.direction(Self.metronome("half", perMinute: 60)) + F.fourQuarters
        let tempo = try Self.tempos(F.score(measures: [body])).first?.tempo
        #expect(Self.near(tempo?.beatsPerSecond, 2.0))
        #expect(tempo?.beatNote == .half)
    }

    /// The metronome's tempo stands in for the missing `<sound tempo>` before the words are classified
    /// (`P2:3494-3499`), so with inference the words are a tempo text by their words that plays it, and without, a
    /// tempo text by its sound — never a staff text that drops the metronome.
    @Test("words and a metronome with no sound tempo are a tempo at the metronome's", arguments: [true, false])
    func wordsAndMetronomeWithoutSound(infer: Bool) throws {
        let body = F.direction(F.words("Allegro") + Self.metronome("quarter", perMinute: 100)) + F.fourQuarters
        let score = try F.score(measures: [body], infer: infer)
        let found = Self.tempos(score)
        #expect(found.count == 1)
        #expect(Self.staffTextCount(score) == 0)
        #expect(Self.near(found.first?.tempo.beatsPerSecond, 100.0 / 60))
        #expect(found.first?.tempo.followText == true)
        // Only the sound branch puts a space between the words and the metronome (`P2:3578`).
        let separator = infer ? "" : " "
        let xml = found.first?.tempo.preservedTextMarkup?.xmlText
        #expect(xml == "Allegro\(separator)<sym>metNoteQuarterUp</sym> = 100")
    }

    @Test("a sound tempo alone is a hidden quarter-note tempo")
    func soundAlone() throws {
        let body = F.direction("", Self.sound(132)) + F.fourQuarters
        let tempo = try Self.tempos(F.score(measures: [body])).first?.tempo
        #expect(Self.near(tempo?.beatsPerSecond, 132.0 / 60))
        #expect(tempo?.visible == false)
        #expect(tempo?.text == nil)
    }

    @Test("`a tempo` carries the sound tempo MuseScore's exporter wrote beside it, not 120 (Review Focus 1)")
    func aTempoCarriesItsSoundTempo() throws {
        let body = F.direction(F.words("a tempo"), Self.sound(90)) + F.fourQuarters
        let tempo = try Self.tempos(F.score(measures: [body])).first?.tempo
        #expect(tempo?.text == "a tempo")
        #expect(Self.near(tempo?.beatsPerSecond, 1.5))
        #expect(tempo?.followText == false)
        #expect(tempo?.textType == .normal)
        #expect(tempo?.visible == true)
    }

    @Test("a tempo word with no number keeps MuseScore's default, 2 beats per second")
    func wordOnlyTempo() throws {
        let body = F.direction(F.words("Allegro")) + F.fourQuarters
        let tempo = try Self.tempos(F.score(measures: [body])).first?.tempo
        #expect(tempo?.text == "Allegro")
        #expect(Self.near(tempo?.beatsPerSecond, 2.0))
        #expect(tempo?.followText == false)
    }

    @Test("the sound branch is not gated by inference")
    func soundBranchIsNotGated() throws {
        let body = F.direction(F.words("Allegro"), Self.sound(100)) + F.fourQuarters
        let tempo = try Self.tempos(F.score(measures: [body], infer: false)).first?.tempo
        #expect(tempo?.text == "Allegro")
        #expect(Self.near(tempo?.beatsPerSecond, 100.0 / 60))
    }

    @Test("a sound tempo directly in the measure becomes a hidden tempo at the next note")
    func measureLevelSound() throws {
        let body = F.quarter("C") + Self.sound(90) + F.quarter("D") + F.quarter("E") + F.quarter("F")
        let found = try Self.tempos(F.score(measures: [body]))
        #expect(found.count == 1)
        #expect(found.first?.position == MeasurePosition(numerator: 1, denominator: 4))
        #expect(Self.near(found.first?.tempo.beatsPerSecond, 1.5))
        #expect(found.first?.tempo.visible == false)
    }

    @Test("a second hidden tempo on the same tick is dropped")
    func duplicateIsDropped() throws {
        let body = F.direction("", Self.sound(100)) + F.direction("", Self.sound(90)) + F.fourQuarters
        let found = try Self.tempos(F.score(measures: [body]))
        #expect(found.count == 1)
        #expect(Self.near(found.first?.tempo.beatsPerSecond, 100.0 / 60))
    }

    /// The tempo text made by its words is added to the segment at once, so `canAddTempoText` sees it
    /// (`P2:2692-2707`, `3525-3538`).
    @Test("a tempo text by its words blocks a second tempo on its tick")
    func wordTempoBlocksTheNext() throws {
        let body = F.direction(F.words("a tempo"), Self.sound(90)) + F.direction("", Self.sound(100)) + F.fourQuarters
        let found = try Self.tempos(F.score(measures: [body]))
        #expect(found.count == 1)
        #expect(found.first?.tempo.text == "a tempo")
        #expect(Self.near(found.first?.tempo.beatsPerSecond, 1.5))
    }

    /// A sound-tempo text whose direction has a `default-y` joins MuseScore's delayed directions (`P2:3672-3677`),
    /// which reach the segment only when the measure is read (`P2:2984-2990`): it does not block the next direction on
    /// its tick, but it blocks a later part's.
    @Test("a sound-tempo text with default-y blocks only from the end of its measure")
    func heldBackTempoBlocksFromTheMeasureEnd() throws {
        let words = F.words("Solo", attributes: "default-y=\"20\"")
        let first = [F.direction(words, Self.sound(100)) + F.direction("", Self.sound(120)) + F.fourQuarters]
        let second = [F.direction("", Self.sound(80)) + F.fourQuarters]
        let found = try Self.tempos(F.score(parts: [first, second]))
        let bpms = found.map { ($0.tempo.beatsPerSecond * 60).rounded() }.sorted()
        #expect(bpms == [100, 120])
    }

    @Test("a first tempo of 120 does not block the next (canAddTempoText, P2:2698)")
    func defaultDoesNotBlock() throws {
        let body = F.direction("", Self.sound(120)) + F.direction("", Self.sound(90)) + F.fourQuarters
        #expect(try Self.tempos(F.score(measures: [body])).count == 2)
    }

    @Test("a tempo written in the second part lands on the score's top staff")
    func secondPartTempo() throws {
        let first = [F.fourQuarters]
        let second = [F.direction("", Self.sound(100)) + F.fourQuarters]
        let found = try Self.tempos(F.score(parts: [first, second]))
        #expect(found.count == 1)
        #expect(found.first?.staff == StaffAddress(partIndex: 0, staffIndexInPart: 0))
    }

    @Test("playback reads it: the downbeat plays the sound tempo")
    func playbackReadsIt() throws {
        let body = F.direction(Self.metronome("quarter", perMinute: 100), Self.sound(100)) + F.fourQuarters
        let score = try F.score(measures: [body, F.fourQuarters])
        let bpm = score.effectiveQuarterBpm(at: .beat(measureIndex: 0, tickInMeasure: 0))
        let later = score.effectiveQuarterBpm(at: .beat(measureIndex: 1, tickInMeasure: 0))
        #expect(abs(bpm - 100) < 1e-6)
        #expect(abs(later - 100) < 1e-6)
    }
}
