import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// Same ambiguity, same fix, as `LyricsVisibilityTests` — see the note there.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// A melisma keeps its extender line unbroken through a mid-system clef, key, meter or start-repeat change.
///
/// The per-measure continuation used to start after ANY header the measure drew, which is right at a system's
/// head (the line must not run under the restated clef) and wrong in the middle of one: the previous bar's rule
/// stops at its barline, so the line showed a gap exactly as wide as the new signature. MuseScore segments a
/// `LyricsLine` per system and pulls only the system's first segment in past the header
/// (`lyricslayout.cpp:765-779`); inside a system the line runs straight through.
@Suite("LayoutEngine — lyric melisma across a signature change")
struct LyricMelismaAcrossSignatureTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    enum Change: CaseIterable, CustomStringConvertible, Sendable {
        case none, key, meter, clef, startRepeat

        var description: String {
            switch self {
            case .none: "no change"
            case .key: "key signature"
            case .meter: "time signature"
            case .clef: "clef"
            case .startRepeat: "start repeat"
            }
        }
    }

    private struct Segment {
        let measureIndex: Int
        let systemIndex: Int
        let localFromX: CGFloat
        let minX: CGFloat
        let maxX: CGFloat
    }

    private static func quarter(_ pitch: Int, lyric: Lyric? = nil) -> VoiceElement {
        .chord(Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: pitch, tpc: 14)]),
            lyrics: lyric.map { [$0] } ?? [],
        ))
    }

    /// Bar 1 opens a melisma on "Ah" that is still held two beats into bar 2 (`ticks` 2400 = a bar and a half
    /// beat past the syllable's own quarter). Bar 2 opens with `change`.
    private static func score(change: Change, breakBefore: Bool = false) -> Score {
        let measure1 = Measure(
            voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .keySignature(KeySignature(concertKey: 0)),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                quarter(67, lyric: Lyric(text: "Ah", ticks: 2400)),
                quarter(65), quarter(64), quarter(62),
            ])],
            lineBreak: breakBefore,
        )
        var opening: [VoiceElement] = []
        var beats = 4
        switch change {
        case .none, .startRepeat: break
        case .key: opening = [.keySignature(KeySignature(concertKey: 2))]
        case .meter:
            opening = [.timeSignature(TimeSignature(numerator: 3, denominator: 4))]
            beats = 3
        case .clef: opening = [.clef(Clef(concertClefType: "F"))]
        }
        let notes = [60, 62, 64, 65].prefix(beats).map { quarter($0) }
        let measure2 = Measure(voices: [Voice(elements: opening + notes)], startRepeat: change == .startRepeat)
        let staff = Staff(measures: [measure1, measure2])
        let part = Part(id: "1", instrument: Instrument(id: "voice"), staves: [staff])
        return Score(division: 480, parts: [part])
    }

    private static func segments(in document: LayoutDocument) -> [Segment] {
        var result: [Segment] = []
        for (systemIndex, system) in document.systems.enumerated() {
            for measure in system.measures {
                let base = system.origin.x + measure.origin.x
                for element in measure.elements {
                    guard case let .lyricsMelisma(from, to, _) = element else { continue }
                    result.append(Segment(
                        measureIndex: measure.measureIndex, systemIndex: systemIndex, localFromX: from.x,
                        minX: base + min(from.x, to.x), maxX: base + max(from.x, to.x),
                    ))
                }
            }
        }
        return result
    }

    private static func layout(_ score: Score) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 900)
    }

    @Test("the rule runs from one bar into the next without a gap", arguments: Change.allCases)
    func continuousWithinASystem(change: Change) throws {
        let document = Self.layout(Self.score(change: change))
        try #require(document.systems.count == 1)
        let segments = Self.segments(in: document)
        let first = try #require(segments.first { $0.measureIndex == 0 })
        let second = try #require(segments.first { $0.measureIndex == 1 })
        #expect(second.localFromX == 0)
        #expect(second.minX <= first.maxX + 0.01)
    }

    /// The other half of the rule, so the fix cannot overreach: at the head of a system the line still starts
    /// past the restated clef and the new key rather than running under them.
    @Test("at a system's head the rule still starts past the header")
    func startsPastTheHeaderAtASystemHead() throws {
        let document = Self.layout(Self.score(change: .key, breakBefore: true))
        try #require(document.systems.count == 2)
        let second = try #require(Self.segments(in: document).first { $0.measureIndex == 1 })
        #expect(second.systemIndex == 1)
        let measure = try #require(document.systems[1].measures.first)
        let keyX = try #require(measure.elements.lazy.compactMap { element -> CGFloat? in
            guard case let .keySignature(_, _, _, _, origin, _) = element else { return nil }
            return origin.x
        }.max())
        #expect(second.localFromX > keyX)
    }
}
