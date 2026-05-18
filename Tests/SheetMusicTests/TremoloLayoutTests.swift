import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutEngine tremolo emission")
struct TremoloLayoutTests {
    /// Build a one-measure score whose single chord (or chord pair) has
    /// the supplied elements.
    private static func score(_ elements: [VoiceElement]) -> Score {
        let measure = Measure(voices: [Voice(elements: elements)])
        let staff = Staff(measures: [measure])
        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [staff],
            )],
        )
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func laidOut(_ s: Score) -> LayoutDocument {
        let opts = ScoreViewOptions(
            staffSize: 28, systemGap: 40, wrapToViewWidth: false,
        )
        let natW = LayoutEngine.naturalContentWidth(score: s, options: opts)
        return LayoutEngine.layout(
            score: s, options: opts, availableWidth: natW,
        )
    }

    @available(macOS 15.0, iOS 16.0, *)
    private static func measureElements(_ doc: LayoutDocument) -> [LayoutElement] {
        doc.systems.first?.measures.first?.elements ?? []
    }

    @Test("Single r16 emits .tremoloBars with .single anchor + barCount 2")
    func single_r16_emits_tremoloBars_with_bar_count_2() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            tremolo: Tremolo(subtype: .r16),
        )
        let doc = Self.laidOut(Self.score([.chord(chord)]))
        let bars = Self.measureElements(doc).compactMap { el -> Int? in
            if case let .tremoloBars(anchor, n) = el,
               case .single = anchor
            {
                return n
            }
            return nil
        }
        #expect(bars == [2])
    }

    @Test("Between c8 emits .tremoloBars with .between anchor + barCount 1")
    func between_c8_emits_tremoloBars_with_anchor_between() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let start = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            tremolo: Tremolo(subtype: .r8, span: .between),
        )
        let follower = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 64, tpc: 18)]),
        )
        let doc = Self.laidOut(Self.score([
            .chord(start), .chord(follower),
        ]))
        let bars = Self.measureElements(doc).compactMap { el -> Int? in
            if case let .tremoloBars(anchor, n) = el,
               case .between = anchor
            {
                return n
            }
            return nil
        }
        #expect(bars == [1])
    }
}
