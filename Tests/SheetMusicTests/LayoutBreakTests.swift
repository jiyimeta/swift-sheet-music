import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicUI
import Testing

@Suite struct LayoutBreakTests {
    /// `<LayoutBreak><subtype>line</subtype>` on a measure parses
    /// into `Measure.lineBreak == true`.
    @Test func parsesLineBreak() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Staff id="1">
              <Measure>
                <voice></voice>
              </Measure>
              <Measure>
                <LayoutBreak>
                  <subtype>line</subtype>
                </LayoutBreak>
                <voice></voice>
              </Measure>
              <Measure>
                <voice></voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        let measures = score.staves[0].measures
        #expect(measures[0].lineBreak == false)
        #expect(measures[1].lineBreak == true)
        #expect(measures[2].lineBreak == false)
    }

    /// LayoutBreak subtypes other than "line" don't trigger the
    /// flag — page / section breaks are honoured separately
    /// (currently unused in our pipeline).
    @Test func ignoresPageBreakSubtype() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Staff id="1">
              <Measure>
                <LayoutBreak>
                  <subtype>page</subtype>
                </LayoutBreak>
                <voice></voice>
              </Measure>
            </Staff>
          </Score>
        </museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        #expect(score.staves[0].measures[0].lineBreak == false)
    }

    /// `LayoutEngine.measureForcesLineBreak(at:staves:)` consults
    /// only staff 0 (line breaks are document-level).
    @Test func helperReadsStaffZero() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let m1 = Measure(voices: [], lineBreak: true)
        let m2 = Measure(voices: [], lineBreak: false)
        let staves = [
            StaffContent(id: 1, measures: [m1, m2]),
            StaffContent(id: 2, measures: [m2, m2]),
        ]
        #expect(LayoutEngine.measureForcesLineBreak(
            at: 0, staves: staves) == true)
        #expect(LayoutEngine.measureForcesLineBreak(
            at: 1, staves: staves) == false)
        // Out-of-range index returns false rather than crashing.
        #expect(LayoutEngine.measureForcesLineBreak(
            at: 99, staves: staves) == false)
    }

    /// Between two forced breaks (or between start-of-score and the
    /// first break), measures should split evenly across systems
    /// rather than greedily packing the first system. Mirrors
    /// MuseScore's "balanced wrap" preference: when an 8-measure
    /// span needs 2 systems to fit, prefer 4+4 over 6+2 or 7+1.
    @Test func balancedWrapBetweenBreaks() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Construct measures wide enough that 8 of them force a
        // 2-system split, but with each measure narrow enough that
        // a greedy packer could pack 6 in the first system. We use
        // a quarter-note chord per measure so the duration-driven
        // width is meaningful.
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)])
        let baseMeasure = Measure(voices: [Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(chord), .chord(chord),
            .chord(chord), .chord(chord),
        ])])
        let measures = (0..<8).map { idx -> Measure in
            var m = baseMeasure
            if idx == 7 { m.lineBreak = true }
            return m
        }
        let staff = StaffContent(id: 1, measures: measures)
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "i",
                articulations: [InstrumentArticulation()]))
        let score = Score(
            division: 480, parts: [part], staves: [staff])
        // Width chosen so 4 measures comfortably fit but 6 don't.
        let opts = ScoreViewOptions(
            staffSize: 14, systemGap: 16, wrapToViewWidth: true)
        let doc = LayoutEngine.layout(
            score: score, options: opts, availableWidth: 280)
        // Two systems, 4 measures each — not 6+2 or 7+1.
        #expect(doc.systems.count == 2)
        #expect(doc.systems[0].measures.count == 4)
        #expect(doc.systems[1].measures.count == 4)
    }

    /// Horizontal mode (`wrapToViewWidth = false`) must ignore
    /// line breaks — the whole score lays out as a single
    /// continuous strip. Mirrors MuseScore's
    /// `LayoutMode::HORIZONTAL_FIXED` branch in
    /// `engraving/rendering/score/systemlayout.cpp:265-269`.
    @Test func horizontalModeIgnoresLineBreaks() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)])
        // Six measures with a forced line break on every odd index.
        let measures = (0..<6).map { idx in
            Measure(
                voices: [Voice(elements: [
                    .chord(chord), .chord(chord),
                    .chord(chord), .chord(chord),
                ])],
                lineBreak: idx % 2 == 1)
        }
        let staff = StaffContent(id: 1, measures: measures)
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "i",
                articulations: [InstrumentArticulation()]))
        let score = Score(
            division: 480, parts: [part], staves: [staff])
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(
                staffSize: 16, systemGap: 16,
                wrapToViewWidth: false),
            availableWidth: 4000)
        // wrapToViewWidth=false → one system holds every measure
        // regardless of LayoutBreaks.
        #expect(doc.systems.count == 1)
        #expect(doc.systems.first?.measures.count == 6)
    }

    /// A score with explicit line breaks every 2 measures produces
    /// one system per pair regardless of how many would otherwise
    /// fit horizontally.
    @Test func layoutBreakForcesSystemSplit() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let chord = Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)])
        // Six measures, with `lineBreak` on indices 1 and 3 (so
        // breaks land *after* measures 2 and 4).
        let measures = (0..<6).map { idx in
            Measure(
                voices: [Voice(elements: [
                    .chord(chord), .chord(chord),
                    .chord(chord), .chord(chord),
                ])],
                lineBreak: idx == 1 || idx == 3)
        }
        let staff = StaffContent(id: 1, measures: measures)
        let part = Part(
            id: "P1",
            instrument: Instrument(
                id: "i",
                articulations: [InstrumentArticulation()]))
        let score = Score(
            division: 480, parts: [part], staves: [staff])
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(
                staffSize: 16, systemGap: 16,
                wrapToViewWidth: true),
            availableWidth: 4000) // wide enough that nothing
                                  // wraps from horizontal overflow
        // Two explicit breaks → three systems.
        #expect(doc.systems.count == 3)
    }
}
