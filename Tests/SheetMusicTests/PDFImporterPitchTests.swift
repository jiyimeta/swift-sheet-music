import CoreGraphics
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicPDF
import Testing

@MainActor struct PDFImporterPitchTests {
    // MARK: - Fixtures

    private func makeMeasure(
        glyphs: [ClassifiedGlyph],
        yLines: [CGFloat] = [490, 495, 500, 505, 510],
    ) -> ImportMeasure {
        ImportMeasure(
            xRange: 50 ... 550,
            glyphs: glyphs,
            leadingBarline: nil,
            trailingBarline: nil,
            staffYLines: yLines,
        )
    }

    private func notehead(
        x: CGFloat, y: CGFloat,
        semantic: SMuFLSemantic = .noteheadBlack,
    ) -> ClassifiedGlyph {
        ClassifiedGlyph(
            raw: RawGlyph(
                codepoint: 0xE0A4, fontName: "Bravura", fontSize: 20,
                origin: CGPoint(x: x, y: y), advance: 5, pageIndex: 0,
            ),
            semantic: semantic,
        )
    }

    private func accidental(
        x: CGFloat, y: CGFloat, kind: SMuFLSemantic,
    ) -> ClassifiedGlyph {
        ClassifiedGlyph(
            raw: RawGlyph(
                codepoint: 0, fontName: "Bravura", fontSize: 20,
                origin: CGPoint(x: x, y: y), advance: 5, pageIndex: 0,
            ),
            semantic: kind,
        )
    }

    private let trebleClef = Clef(concertClefType: "G")
    private let bassClef = Clef(concertClefType: "F")
    private let cMajor = KeySignature(concertKey: 0)
    private let gMajor = KeySignature(concertKey: 1) // F#
    private let fMajor = KeySignature(concertKey: -1) // Bb

    // MARK: - Clef → MIDI on staff lines

    @Test func trebleBottomLineIsE4() {
        let m = makeMeasure(glyphs: [notehead(x: 100, y: 490)])
        let pitches = PDFImporter.decodePitches(
            measure: m, activeClef: trebleClef, activeKey: cMajor,
        )
        #expect(pitches.count == 1)
        #expect(pitches.first?.midi == 64)
    }

    @Test func trebleMidLineIsB4() {
        let m = makeMeasure(glyphs: [notehead(x: 100, y: 500)])
        let pitches = PDFImporter.decodePitches(
            measure: m, activeClef: trebleClef, activeKey: cMajor,
        )
        #expect(pitches.first?.midi == 71)
    }

    @Test func trebleTopLineIsF5() {
        let m = makeMeasure(glyphs: [notehead(x: 100, y: 510)])
        let pitches = PDFImporter.decodePitches(
            measure: m, activeClef: trebleClef, activeKey: cMajor,
        )
        #expect(pitches.first?.midi == 77)
    }

    @Test func bassBottomLineIsG2() {
        let m = makeMeasure(glyphs: [notehead(x: 100, y: 490)])
        let pitches = PDFImporter.decodePitches(
            measure: m, activeClef: bassClef, activeKey: cMajor,
        )
        #expect(pitches.first?.midi == 43)
    }

    @Test func bassTopLineIsA3() {
        let m = makeMeasure(glyphs: [notehead(x: 100, y: 510)])
        let pitches = PDFImporter.decodePitches(
            measure: m, activeClef: bassClef, activeKey: cMajor,
        )
        #expect(pitches.first?.midi == 57)
    }

    // MARK: - Key signature defaults

    @Test func sharpInKeyOfGAppliesByDefault() {
        // F line (top line in treble) under G major (1 sharp = F#).
        let m = makeMeasure(glyphs: [notehead(x: 100, y: 510)])
        let pitches = PDFImporter.decodePitches(
            measure: m, activeClef: trebleClef, activeKey: gMajor,
        )
        #expect(pitches.first?.midi == 78)
    }

    @Test func flatInKeyOfFAppliesByDefault() {
        // B line (mid line in treble) under F major (1 flat = Bb).
        let m = makeMeasure(glyphs: [notehead(x: 100, y: 500)])
        let pitches = PDFImporter.decodePitches(
            measure: m, activeClef: trebleClef, activeKey: fMajor,
        )
        #expect(pitches.first?.midi == 70)
    }

    // MARK: - Local accidentals

    @Test func localSharpAccidentalRaisesPitch() {
        // C major, F-line (y=510). Sharp glyph just to the left of the
        // notehead at the same y ⇒ F#5 (78).
        let m = makeMeasure(glyphs: [
            accidental(x: 95, y: 510, kind: .accidentalSharp),
            notehead(x: 105, y: 510),
        ])
        let pitches = PDFImporter.decodePitches(
            measure: m, activeClef: trebleClef, activeKey: cMajor,
        )
        #expect(pitches.first?.midi == 78)
    }

    @Test func localAccidentalPropagatesToEndOfMeasure() {
        // C major, two F-line noteheads. Only the first carries the
        // explicit sharp; the second inherits via the local-accidental
        // state machine.
        let m = makeMeasure(glyphs: [
            accidental(x: 95, y: 510, kind: .accidentalSharp),
            notehead(x: 105, y: 510),
            notehead(x: 200, y: 510),
        ])
        let pitches = PDFImporter.decodePitches(
            measure: m, activeClef: trebleClef, activeKey: cMajor,
        )
        #expect(pitches.count == 2)
        #expect(pitches.allSatisfy { $0.midi == 78 })
    }

    @Test func naturalCancelsKeyAccidental() {
        // G major: F-line would default to F#5 (78). An explicit
        // natural on that head returns it to F natural (77).
        let m = makeMeasure(glyphs: [
            accidental(x: 95, y: 510, kind: .accidentalNatural),
            notehead(x: 105, y: 510),
        ])
        let pitches = PDFImporter.decodePitches(
            measure: m, activeClef: trebleClef, activeKey: gMajor,
        )
        #expect(pitches.first?.midi == 77)
    }

    // TODO: cross-octave non-propagation test. The current state
    // machine keys local accidentals by (diatonicStep, octave), so a
    // sharp on F5 should not affect F4. Adding that test requires a
    // realistic ledger-line y for F4 that round-trips through the
    // y → step → octave math; deferred to Task 15 round-trip work.
}
