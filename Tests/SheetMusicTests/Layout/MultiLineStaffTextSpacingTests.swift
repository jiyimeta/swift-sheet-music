import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

/// A multi-line staff text above a LOWER staff must push that staff down far enough to clear the staff above it.
///
/// The per-staff skyline in `buildSystem` reads `elementYPoints`, which reported a staff text by its anchor alone —
/// the bottom of the whole stack. For one line the 2 sp baseline above every lower staff absorbed the line the
/// anchor leaves out; every extra line was missed, so a three-line text rose into the lyrics of the staff above.
@Suite("Multi-line staff text — staff spacing")
struct MultiLineStaffTextSpacingTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private static let lower = StaffAddress(partIndex: 1, staffIndexInPart: 0)
    private static let metrics = StaffMetrics(staffSize: 28)

    @Test("a four-line text above the lower staff stays clear of the upper staff's lyrics")
    func multiLineTextClearsUpperLyrics() throws {
        let document = Self.layout(text: "one\ntwo\nthree\nfour")
        let lyric = try #require(Self.inkRects(in: document) { element in
            if case .textMark(.lyrics, _, _) = element { return true }
            return false
        }.max { $0.maxY < $1.maxY })
        let text = try #require(Self.inkRects(in: document) { element in
            if case .staffText = element { return true }
            return false
        }.first)
        #expect(text.minY > lyric.maxY, "text top \(text.minY) must sit below the lyric bottom \(lyric.maxY)")
    }

    @Test("a one-line text leaves the staff gap exactly where it was")
    func oneLineTextKeepsTheGap() {
        // The anchor-only reading was tuned for one line; the multi-line fix must not move it.
        let single = Self.lowerStaffY(Self.layout(text: "one"))
        let none = Self.lowerStaffY(Self.layout(text: nil))
        let multi = Self.lowerStaffY(Self.layout(text: "one\ntwo\nthree"))
        #expect(single >= none)
        #expect(multi > single)
    }

    private static func layout(text: String?) -> LayoutDocument {
        var lyricChord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 67, tpc: 15)]))
        lyricChord.lyrics = [Lyric(text: "lyric")]
        let lowerChord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))
        let system: [PositionedSystemElement] = text.map {
            [PositionedSystemElement(
                position: .start, element: .staffText(StaffText(text: $0, isSystemText: false)),
                originalStaff: lower,
            )]
        } ?? []
        let score = Score(division: 480, parts: [
            Part(id: "P1", instrument: Instrument(id: "voice"), staves: [
                Staff(measures: [Measure(voices: [Voice(elements: [.chord(lyricChord)])])]),
            ]),
            Part(id: "P2", instrument: Instrument(id: "piano"), staves: [
                Staff(measures: [Measure(voices: [Voice(elements: [.chord(lowerChord)])])]),
            ]),
        ], systemMeasures: [SystemMeasure(elements: system)])
        return LayoutEngine.layout(score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 800)
    }

    private static func inkRects(
        in document: LayoutDocument, where matches: (LayoutElement) -> Bool,
    ) -> [CGRect] {
        document.systems.flatMap(\.measures).flatMap(\.elements).filter(matches).flatMap {
            TextInkGeometry.rects(for: $0, metrics: metrics) ?? []
        }
    }

    private static func lowerStaffY(_ document: LayoutDocument) -> CGFloat {
        document.systems.first?.staffOrigins.last?.y ?? 0
    }
}
