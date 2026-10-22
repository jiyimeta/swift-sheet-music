#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

/// An arpeggio, a chord line and a tremolo each name the chord that carries them, which is the address their
/// commands take: a click on the ink selects it, and its removal command takes it off that chord.
@Suite("Chord ornament selection")
struct ChordOrnamentSelectionTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func chord(_ pitches: [Int], _ duration: NoteDuration) -> Chord {
        Chord(duration: duration, notes: ChordNotes(pitches.map { Note(pitch: $0, tpc: 14) }))
    }

    /// Bar 0: an arpeggiated whole-note triad. Bar 1: a whole note with a fall. Bar 2: a half note with a tremolo.
    private static func score() -> Score {
        var arpeggiated = chord([60, 64, 67], .whole)
        arpeggiated.arpeggio = Arpeggio(subtype: 0)
        var falling = chord([67], .whole)
        falling.chordLines = [ChordLine(kind: .fall)]
        var trembling = chord([72], .half)
        trembling.tremolo = Tremolo(subtype: .r16)
        let measures = [
            Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .keySignature(KeySignature(concertKey: 0)),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(arpeggiated),
            ])]),
            Measure(voices: [Voice(elements: [.chord(falling)])]),
            Measure(voices: [Voice(elements: [.chord(trembling), .rest(duration: .half)])]),
        ]
        return Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "piano"), staves: [Staff(measures: measures)]),
        ])
    }

    private static func slot(_ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static let targets: [ScoreElementID] = [
        .arpeggio(anchor: slot(0, 3)), .chordLine(anchor: slot(1, 0)), .tremolo(anchor: slot(2, 0)),
    ]

    @Test("each names its chord, a click on its ink selects it, and its removal takes it off", arguments: targets)
    func selectsAndRemoves(_ id: ScoreElementID) throws {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        var score = Self.score()
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 2000)
        let drawn = document.systems.flatMap(\.measures).flatMap(\.elements).compactMap(\.elementID)
        #expect(drawn.contains(id))

        let tester = ScoreHitTester(document: document)
        let target = ScoreHitTarget(elementID: id)
        let rect = try #require(tester.elementHitRect(for: target))
        #expect(tester.hitTest(at: CGPoint(x: rect.midX, y: rect.midY)) == target)

        let removal = try #require(id.removalCommand)
        _ = try removal.apply(to: &score)
        let anchor = try #require(id.anchor)
        guard case let .chord(chord)? = score[anchor] else {
            Issue.record("the anchor no longer names a chord")
            return
        }
        #expect(chord.arpeggio == nil)
        #expect(chord.chordLines.isEmpty)
        #expect(chord.tremolo == nil)
    }
}
