#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// Geometry side-car tests. Copyright-clean: synthetic glyphs / collector
    /// records (the same unit style as `PDFImporterRhythmTests`), so no PDF
    /// fixture is needed. Covers (A3) per-note rect capture in `decodeRhythm`,
    /// (A5) the `voiceAssignment` permutation that backs both the value path
    /// and the geometry indices, and (B) the `PDFScoreGeometry` query API.
    @MainActor struct PDFImporterGeometryTests {
        // MARK: - Fixtures

        private func notehead(
            x: CGFloat, y: CGFloat, midi: Int,
        ) -> (ClassifiedGlyph, PDFImporter.DecodedPitch) {
            let g = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 6,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .noteheadBlack,
            )
            let dp = PDFImporter.DecodedPitch(
                midi: midi, tpc: 14, noteheadX: x, noteheadY: y, glyph: g,
            )
            return (g, dp)
        }

        private func makeMeasure(
            _ glyphs: [ClassifiedGlyph],
        ) -> ImportMeasure {
            ImportMeasure(
                xRange: 50 ... 550, glyphs: glyphs,
                leadingBarline: nil, trailingBarline: nil,
                staffYLines: [490, 495, 500, 505, 510],
            )
        }

        // MARK: - A3: per-note rect capture in decodeRhythm

        @Test func chordCapturesAlignedPerNoteRects() {
            // Two noteheads sharing x=100 on one stem → one 2-note chord.
            let (g0, dp0) = notehead(x: 100, y: 505, midi: 71)
            let (g1, dp1) = notehead(x: 100, y: 495, midi: 74)
            let stem = PathSegment(
                kind: .vertical,
                rect: CGRect(x: 100, y: 495, width: 0, height: 40),
                lineWidth: 0.5, pageIndex: 0,
            )
            let rhythm = PDFImporter.decodeRhythm(
                measure: makeMeasure([g0, g1]),
                decoded: [dp0, dp1], paths: [stem],
            )
            let chord = try? #require(rhythm.first)
            #expect(rhythm.count == 1)
            #expect(chord?.chord.notes.count == 2)
            // Lockstep: one rect per surviving note, all positive-area.
            #expect(chord?.noteRects.count == chord?.chord.notes.count)
            for r in chord?.noteRects ?? [] {
                #expect(r.pageIndex == 0)
                #expect(r.rect.width > 0 && r.rect.height > 0)
            }
            // onsetRect is the union — taller than either single notehead.
            let onset = chord?.onsetRect
            #expect(onset != nil)
            if let onset, let rects = chord?.noteRects {
                for r in rects {
                    #expect(onset.rect.contains(CGPoint(x: r.rect.midX, y: r.rect.midY)))
                }
            }
        }

        @Test func restCapturesOnsetRectAndNoNoteRects() {
            let restGlyph = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: 200, y: 500), advance: 6,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .rest(.quarter),
            )
            let rhythm = PDFImporter.decodeRhythm(
                measure: makeMeasure([restGlyph]), decoded: [], paths: [],
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.isRest == true)
            #expect(rhythm.first?.noteRects.isEmpty == true)
            #expect(rhythm.first?.onsetRect != nil)
        }

        // MARK: - A5: voiceAssignment matches assignVoices

        private func element(
            x: CGFloat, stem: StemDirection, midi: Int,
        ) -> RhythmElement {
            RhythmElement(
                chord: Chord(duration: .quarter, notes: [Note(pitch: midi, tpc: 14)]),
                x: x, y: 500, stemDirection: stem, beamGroup: nil,
            )
        }

        @Test func voiceAssignmentSingleVoiceIsXSorted() {
            // Distinct x (>3pt apart) ⇒ single voice, position = x-rank.
            let els = [
                element(x: 300, stem: .up, midi: 60),
                element(x: 100, stem: .up, midi: 62),
                element(x: 200, stem: .up, midi: 64),
            ]
            let placements = PDFImporter.voiceAssignment(elements: els, staffMidY: 500)
            #expect(placements.map(\.voice) == [0, 0, 0])
            // Input index 0 (x=300) is last; index 1 (x=100) first; index 2 mid.
            #expect(placements[0].position == 2)
            #expect(placements[1].position == 0)
            #expect(placements[2].position == 1)
            // assignVoices builds one voice with the chords in x order.
            let voices = PDFImporter.assignVoices(
                elements: els, measureXRange: 50 ... 550,
                timeSignature: TimeSignature(numerator: 4, denominator: 4),
                staffMidY: 500,
            )
            #expect(voices.count == 1)
            #expect(voices[0].elements.count == 3)
        }

        @Test func voiceAssignmentTwoVoiceSplitsByStem() {
            // Coincident x ⇒ two voices: stem-up → voice 0, stem-down → voice 1.
            let els = [
                element(x: 100, stem: .up, midi: 72),
                element(x: 100, stem: .down, midi: 48),
            ]
            let placements = PDFImporter.voiceAssignment(elements: els, staffMidY: 500)
            #expect(placements[0].voice == 0)
            #expect(placements[1].voice == 1)
            let voices = PDFImporter.assignVoices(
                elements: els, measureXRange: 50 ... 550,
                timeSignature: TimeSignature(numerator: 4, denominator: 4),
                staffMidY: 500,
            )
            // Two voices always emitted (the second may be empty elsewhere).
            #expect(voices.count == 2)
            #expect(voices[0].elements.count == 1)
            #expect(voices[1].elements.count == 1)
        }

        // MARK: - B: PDFScoreGeometry query API via the collector

        private func builtGeometry() -> PDFScoreGeometry {
            let c = PDFGeometryCollector()
            c.setPageSizes([0: CGSize(width: 600, height: 800)])
            c.setSlotToStaff([0: StaffAddress(partIndex: 0, staffIndexInPart: 0)])
            c.recordSystem(yRange: 400 ... 520, pageIndex: 0)
            c.recordMeasureCell(
                slot: 0, measureIndex: 0,
                xRange: 50 ... 250, yLines: [490, 495, 500, 505, 510], pageIndex: 0,
            )
            let n0 = PDFElementRect(pageIndex: 0, rect: CGRect(x: 96, y: 500, width: 8, height: 9))
            let n1 = PDFElementRect(pageIndex: 0, rect: CGRect(x: 96, y: 491, width: 8, height: 9))
            c.recordItem(
                slot: 0, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
                isRest: false,
                onsetRect: PDFElementRect(
                    pageIndex: 0, rect: CGRect(x: 96, y: 491, width: 8, height: 18),
                ),
                noteRects: [n0, n1],
            )
            c.recordItem(
                slot: 0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
                isRest: true,
                onsetRect: PDFElementRect(
                    pageIndex: 0, rect: CGRect(x: 176, y: 496, width: 6, height: 9),
                ),
                noteRects: [],
            )
            return c.finalize()
        }

        private var staff0: StaffAddress {
            StaffAddress(partIndex: 0, staffIndexInPart: 0)
        }

        @Test func lookupPerNoteAndChordAndRest() {
            let geo = builtGeometry()
            let note1 = NoteID(
                staff: staff0, measureIndex: 0, voiceIndex: 0,
                elementIndex: 0, noteIndexInChord: 1,
            )
            #expect(geo.rect(for: note1)?.rect.minY == 491)
            // ScoreItemID.note(lead) → chord union (height 18).
            let lead = NoteID(
                staff: staff0, measureIndex: 0, voiceIndex: 0,
                elementIndex: 0, noteIndexInChord: 0,
            )
            #expect(geo.rect(for: .note(lead))?.rect.height == 18)
            let rest = RestID(
                staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
            )
            #expect(geo.rect(for: .rest(rest)) != nil)
            #expect(geo.measureRect(staff: staff0, measureIndex: 0) != nil)
        }

        @Test func hitTestResolvesNoteRestAndMeasureFallback() {
            let geo = builtGeometry()
            // Point inside the upper notehead → that exact note.
            let hitNote = geo.hitTest(pageIndex: 0, point: CGPoint(x: 100, y: 495))
            if case let .note(id) = hitNote {
                #expect(id.noteIndexInChord == 1)
            } else {
                Issue.record("expected a note hit, got \(String(describing: hitNote))")
            }
            // Point inside the rest glyph → the rest.
            let hitRest = geo.hitTest(pageIndex: 0, point: CGPoint(x: 179, y: 500))
            if case .rest = hitRest {} else {
                Issue.record("expected a rest hit, got \(String(describing: hitRest))")
            }
            // Far from any glyph but inside the measure cell → leftmost item.
            let fallback = geo.hitTest(
                pageIndex: 0, point: CGPoint(x: 240, y: 500), tolerance: 5,
            )
            #expect(fallback != nil)
        }

        @Test func cursorRectSpansSystemHeight() {
            let geo = builtGeometry()
            let lead = NoteID(
                staff: staff0, measureIndex: 0, voiceIndex: 0,
                elementIndex: 0, noteIndexInChord: 0,
            )
            let cursor = geo.cursorRect(
                for: .item(.note(lead)), in: Score(division: 480, source: .pdf),
            )
            #expect(cursor?.pageIndex == 0)
            // Grew to the system's full y-range (400…520 ⇒ height 120).
            #expect(cursor?.rect.height == 120)
            #expect(geo.systemRect(containing: .note(lead)) != nil)
        }
    }
#endif
