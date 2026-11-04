@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// A breath at the head of a bar follows the previous bar's last chord, so its engraved glyph names that chord — the
/// address `SetBreath(after:)` takes. Before this it had no identity at all: nothing could select it, so nothing could
/// delete it (user report 2026-11-01, a MuseScore file with a comma at the head of bars 9, 11, 34 …).
@Suite("A bar-head breath's engraved identity")
struct BarHeadBreathIdentityTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let comma = Breath(kind: .breathMark(.comma), pause: 0)

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func chord(_ pitch: Int, _ duration: NoteDuration) -> VoiceElement {
        .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: 14)]))
    }

    private static func score(_ bars: [VoiceElement]...) -> Score {
        let staff = Staff(defaultClefType: "G", measures: bars.map { Measure(voices: [Voice(elements: $0)]) })
        return Score(division: 480, parts: [Part(id: "a", instrument: Instrument(id: "a"), staves: [staff])])
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func breathIDs(_ score: Score, cache: LayoutCache? = nil, width: Int = 1000) -> [ScoreElementID?] {
        LayoutEngine.layout(score: score, options: .init(), availableWidth: .init(width), cache: cache)
            .systems.flatMap(\.measures).flatMap { $0.elements + $0.invisibleElements }
            .filter { if case .breath = $0 { true } else { false } }
            .map(\.elementID)
    }

    @Test("it names the chord ending the bar before, and deleting through that name removes it")
    func namesThePreviousBarsLastChord() throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score(
            [Self.chord(60, .half), Self.chord(64, .half)],
            [.breath(Self.comma), Self.chord(65, .whole)],
        )
        let ids = Self.breathIDs(score)
        #expect(ids == [.breath(anchor: Self.slot(0, 1))])
        let anchor = try #require(ids.first??.anchor)
        _ = try SetBreath(after: anchor, kind: nil, pause: 0).apply(to: &score)
        #expect(Self.breathIDs(score).isEmpty)
        #expect(score.parts[0].staves[0].measures[1].voices[0].elements.values == [Self.chord(65, .whole)])
    }

    @Test("it names the same chord when the barline is a line break")
    func acrossASystemBreak() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Narrow enough that every bar starts its own system: the bar before lives in another system entirely.
        let score = Self.score(
            [Self.chord(60, .whole)],
            [.breath(Self.comma), Self.chord(65, .whole)],
        )
        #expect(LayoutEngine.layout(score: score, options: .init(), availableWidth: 120).systems.count == 2)
        #expect(Self.breathIDs(score, width: 120) == [.breath(anchor: Self.slot(0, 0))])
    }

    @Test("a bar ending on a rest names that rest, as a breath after a rest within a bar does")
    func restEndedBar() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.score(
            [Self.chord(60, .half), .rest(duration: .half)],
            [.breath(Self.comma), Self.chord(65, .whole)],
        )
        #expect(Self.breathIDs(score) == [.breath(anchor: Self.slot(0, 1))])
    }

    @Test("a bar ending on a measure repeat leaves it unnamed: no timed element of its own ends the bar")
    func measureRepeatEndedBar() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.score(
            [Self.chord(60, .whole)],
            [.measureRepeat(MeasureRepeat(numMeasures: 1, duration: .measure))],
            [.breath(Self.comma), Self.chord(65, .whole)],
        )
        #expect(Self.breathIDs(score) == [nil])
    }

    @Test("an edit to the bar before re-derives the name even where nothing in the breath's own bar changed")
    func cacheFollowsTheBarBefore() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let score = Self.score(
            [Self.chord(60, .half), Self.chord(64, .half)],
            [.breath(Self.comma), Self.chord(65, .whole)],
        )
        for width in [1000, 120] {
            let cache = LayoutCache()
            #expect(Self.breathIDs(score, cache: cache, width: width) == [.breath(anchor: Self.slot(0, 1))])
            var edited = score
            edited.parts.updateValue(at: 0) { part in
                part.staves.updateValue(at: 0) { staff in
                    staff.measures[0].voices[0].elements = [Self.chord(60, .whole)]
                }
            }
            #expect(Self.breathIDs(edited, cache: cache, width: width) == [.breath(anchor: Self.slot(0, 0))])
            edited.parts.updateValue(at: 0) { part in
                part.staves.updateValue(at: 0) { staff in
                    staff.measures[0].voices[0].elements = [
                        Self.chord(60, .quarter), Self.chord(62, .quarter), Self.chord(64, .half),
                    ]
                }
            }
            #expect(Self.breathIDs(edited, cache: cache, width: width) == [.breath(anchor: Self.slot(0, 2))])
        }
    }
}
