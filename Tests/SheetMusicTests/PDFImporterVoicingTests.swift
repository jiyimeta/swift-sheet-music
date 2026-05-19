#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterVoicingTests {
        // MARK: - Fixtures

        private func element(
            x: CGFloat,
            y: CGFloat,
            duration: NoteDuration,
            stem: StemDirection? = .up,
            midi: Int = 60,
        ) -> RhythmElement {
            let note = Note(pitch: midi, tpc: 14)
            return RhythmElement(
                chord: Chord(duration: duration, notes: [note]),
                x: x,
                y: y,
                stemDirection: stem,
                beamGroup: nil,
            )
        }

        private func rest(
            x: CGFloat, y: CGFloat, duration: NoteDuration,
        ) -> RhythmElement {
            RhythmElement(
                chord: Chord(duration: duration, notes: []),
                x: x,
                y: y,
                stemDirection: nil,
                beamGroup: nil,
            )
        }

        private let xRange: ClosedRange<CGFloat> = 50 ... 550
        private let four4 = TimeSignature(numerator: 4, denominator: 4)
        private let staffMidY: CGFloat = 500

        // MARK: - Tests

        @Test func sequentialQuartersAreOneVoice() {
            // 4 quarters in 4/4. xRange spans 500 px → 125 px per quarter,
            // so elements must be spaced at least 125 px apart for the
            // intervals to be disjoint.
            let elements = [
                element(x: 50, y: 500, duration: .quarter),
                element(x: 175, y: 500, duration: .quarter),
                element(x: 300, y: 500, duration: .quarter),
                element(x: 425, y: 500, duration: .quarter),
            ]
            let voices = PDFImporter.assignVoices(
                elements: elements,
                measureXRange: xRange,
                timeSignature: four4,
                staffMidY: staffMidY,
            )
            #expect(voices.count == 1)
            #expect(voices[0].elements.count == 4)
        }

        @Test func overlappingNotesAreMultiVoice() {
            // Half (stem-up) at x=100 covers 0..2 quarters; quarter
            // (stem-down) at x=100 starts at 0 — they overlap.
            let half = element(x: 100, y: 500, duration: .half, stem: .up)
            let quarter = element(x: 100, y: 500, duration: .quarter, stem: .down)
            let voices = PDFImporter.assignVoices(
                elements: [half, quarter],
                measureXRange: xRange,
                timeSignature: four4,
                staffMidY: staffMidY,
            )
            #expect(voices.count == 2)
            #expect(voices[0].elements == [.chord(half.chord)])
            #expect(voices[1].elements == [.chord(quarter.chord)])
        }

        @Test func stemDirectionDecidesVoice() {
            let up = element(x: 100, y: 500, duration: .quarter, stem: .up)
            let down = element(x: 100, y: 500, duration: .quarter, stem: .down)
            // Add a half-note stem-up at the same location to force overlap
            // (two coincident quarters alone would have identical intervals
            // and still trigger multi-voice; explicit overlap keeps the
            // intent obvious.)
            let voices = PDFImporter.assignVoices(
                elements: [up, down],
                measureXRange: xRange,
                timeSignature: four4,
                staffMidY: staffMidY,
            )
            #expect(voices.count == 2)
            #expect(voices[0].elements == [.chord(up.chord)])
            #expect(voices[1].elements == [.chord(down.chord)])
        }

        @Test func restAboveMidlineGoesToVoice1() {
            // Multi-voice trigger: stem-up half + rest at same x; rest y
            // is above the staff midline → voice 1.
            let half = element(x: 100, y: 500, duration: .half, stem: .up)
            let r = rest(x: 100, y: 520, duration: .quarter)
            let voices = PDFImporter.assignVoices(
                elements: [half, r],
                measureXRange: xRange,
                timeSignature: four4,
                staffMidY: staffMidY,
            )
            #expect(voices.count == 2)
            // voice 1 has the half (stem-up) AND the high rest
            #expect(voices[0].elements.contains(.chord(r.chord)))
            #expect(voices[0].elements.contains(.chord(half.chord)))
            #expect(voices[1].elements.isEmpty)
        }

        @Test func restBelowMidlineGoesToVoice2() {
            let half = element(x: 100, y: 500, duration: .half, stem: .up)
            let r = rest(x: 100, y: 480, duration: .quarter)
            let voices = PDFImporter.assignVoices(
                elements: [half, r],
                measureXRange: xRange,
                timeSignature: four4,
                staffMidY: staffMidY,
            )
            #expect(voices.count == 2)
            #expect(voices[0].elements == [.chord(half.chord)])
            #expect(voices[1].elements == [.chord(r.chord)])
        }

        @Test func stemlessHighChordVoice1() {
            // Two whole-note chords at same x, no stem, different y.
            let high = element(x: 100, y: 520, duration: .whole, stem: nil)
            let low = element(x: 100, y: 480, duration: .whole, stem: nil)
            let voices = PDFImporter.assignVoices(
                elements: [high, low],
                measureXRange: xRange,
                timeSignature: four4,
                staffMidY: staffMidY,
            )
            #expect(voices.count == 2)
            #expect(voices[0].elements == [.chord(high.chord)])
            #expect(voices[1].elements == [.chord(low.chord)])
        }

        @Test func voice1CollisionEmitsDiagnostic() {
            // Three coincident chords all wanting voice 1: stem-up + a
            // stemless-high + another stem-up. The 2nd-and-later voice-1
            // assignments at the same x trigger the warning.
            let up1 = element(x: 100, y: 500, duration: .quarter, stem: .up)
            let up2 = element(x: 100, y: 500, duration: .quarter, stem: .up, midi: 64)
            let down = element(x: 100, y: 500, duration: .quarter, stem: .down)
            var captured: [PDFImportDiagnostic] = []
            let voices = PDFImporter.assignVoices(
                elements: [up1, up2, down],
                measureXRange: xRange,
                timeSignature: four4,
                staffMidY: staffMidY,
                diagnostics: { captured.append($0) },
                location: "page 1, measure 1",
            )
            #expect(voices.count == 2)
            #expect(captured.contains { $0.severity == .warning })
        }
    }
#endif
