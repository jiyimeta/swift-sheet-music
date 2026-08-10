#if !os(Android)
    import CoreGraphics
    import Foundation
    import SheetMusic
    @testable import SheetMusicCore
    import SheetMusicLayoutApple
    @testable import SheetMusicMSCX
    @testable import SheetMusicPDF
    import Testing

    /// A chord's notes must come out in a canonical order, independent of the
    /// order the glyphs arrived in.
    ///
    /// WHY. `buildScore` used to emit a chord's notes in glyph-stream order,
    /// which carries no musical convention at all — measured on one real
    /// MuseScore PDF, the same document produced `[64, 67, 71]` (ascending),
    /// `[71, 67]` (descending) and `[76, 69, 72]` (neither). That made the
    /// importer's output depend on an accident of the content stream, and it
    /// is the ONLY thing that did: feeding the identical glyph multiset in a
    /// different order changed nothing else. Reordering the paths or the
    /// texts changed nothing; moving every notehead before or after every
    /// other glyph changed nothing; reordering the noteheads AMONG THEMSELVES
    /// changed the output, and the per-chord pitch arrays matched again as
    /// soon as each chord's own array was sorted.
    ///
    /// This matters beyond tidiness. A raster front-end cannot reproduce a
    /// PDF's content-stream order — it emits glyphs in scan order — so an
    /// order-sensitive `buildScore` could never agree with the vector import
    /// of the same page, which is exactly what the OMR programme's P0-G1
    /// gate asserts.
    ///
    /// ASCENDING PITCH is not an invented rule. MuseScore keeps a chord's
    /// notes sorted that way itself (`Chord::add` in `engraving/dom/chord.cpp`
    /// sorts on insert, "use pitch instead, and line as a second sort
    /// criteria"), and this package's MSCX decoder preserves document order —
    /// so every score parsed from a real MuseScore file already has ascending
    /// chords. `parserAgreesThatChordNotesAscend` below pins that against the
    /// repository's own fixtures. The importer was the outlier.
    @MainActor struct PDFImporterChordNoteOrderTests {
        private nonisolated static var bravuraAvailable: Bool {
            guard #available(macOS 15.0, *) else { return false }
            return BravuraFont.register
        }

        private static let bravuraFontName = "Bravura"
        private static let staffTop: CGFloat = 700
        private static let lineGap: CGFloat = 5
        private static let midLine = staffTop - 2 * lineGap

        private static func staffLines() -> [PDFFixtureBuilder.PathPlacement] {
            (0 ..< 5).map {
                PDFFixtureBuilder.PathPlacement(
                    origin: CGPoint(x: 60, y: staffTop - CGFloat($0) * lineGap),
                    kind: .horizontal(width: 260),
                )
            }
        }

        /// Distance from a notehead's origin to its own stem — the same
        /// value `PDFSyntheticTupletTests` uses, inside `nearestStem`'s ±7pt
        /// window and to the right of the origin so the stem reads as
        /// stem-up.
        private static let stemOffset: CGFloat = 5.5
        private static let noteX: CGFloat = 150

        private static func blackNotehead(y: CGFloat)
            -> PDFFixtureBuilder.GlyphPlacement
        {
            PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: "\u{E0A4}", fontName: bravuraFontName,
                fontSize: 4 * lineGap, origin: CGPoint(x: noteX, y: y),
            )
        }

        /// One bar holding a single three-note chord: three black noteheads
        /// at ONE x, on three staff positions, under ONE stem.
        ///
        /// A stem is what makes this a chord rather than three unrelated
        /// notes — the voicing pass groups noteheads by the stem they share.
        /// A first draft used stemless whole noteheads and the importer split
        /// them across two voices, which would have made every assertion here
        /// vacuous; `theFixtureProducesOneChordOfThreeNotes` is the guard
        /// that caught it and keeps catching it.
        ///
        /// The three noteheads are listed in `order`, which is the ONLY thing
        /// that varies between the fixtures below.
        private static func fixture(order: [Int]) -> Data {
            let clef = PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: "\u{E050}", fontName: bravuraFontName,
                fontSize: 4 * lineGap,
                origin: CGPoint(x: 66, y: staffTop - 3 * lineGap),
            )
            // Three distinct staff positions a third apart, at one x.
            let ys = [midLine, midLine + lineGap, midLine + 2 * lineGap]
            let heads = order.map { blackNotehead(y: ys[$0]) }
            // One stem, from the lowest notehead to well above the highest.
            let stem = PDFFixtureBuilder.PathPlacement(
                origin: CGPoint(x: noteX + stemOffset, y: ys[0]),
                kind: .vertical(height: ys[2] - ys[0] + 18), lineWidth: 0.8,
            )
            return PDFFixtureBuilder.build(
                glyphs: [clef] + heads, paths: staffLines() + [stem],
                dropToUnicodeCMaps: true,
            )
        }

        private static func chords(_ score: Score) -> [[Int]] {
            var out: [[Int]] = []
            for part in score.parts {
                for staff in part.staves {
                    for measure in staff.measures {
                        for voice in measure.voices {
                            for element in voice.elements {
                                if case let .chord(chord) = element, !chord.notes.isEmpty {
                                    out.append(chord.notes.map(\.pitch))
                                }
                            }
                        }
                    }
                }
            }
            return out
        }

        /// THE INVARIANT. Three orderings of the same three noteheads must
        /// import to the same `Score` — not merely the same pitches, the same
        /// value, because that is what gate P0-G1 compares.
        @Test(.enabled(if: bravuraAvailable))
        func glyphOrderDoesNotChangeTheImportedScore() throws {
            let ascending = try PDFImporter.parse(pdfData: Self.fixture(order: [0, 1, 2]))
            let descending = try PDFImporter.parse(pdfData: Self.fixture(order: [2, 1, 0]))
            let shuffled = try PDFImporter.parse(pdfData: Self.fixture(order: [1, 2, 0]))
            try #require(!Self.chords(ascending).isEmpty)
            #expect(descending == ascending)
            #expect(shuffled == ascending)
        }

        /// And the canonical order is ascending pitch, so the importer agrees
        /// with what the MSCX parser yields for a real MuseScore file.
        @Test(.enabled(if: bravuraAvailable))
        func importedChordNotesAscend() throws {
            for order in [[0, 1, 2], [2, 1, 0], [1, 2, 0]] {
                let score = try PDFImporter.parse(pdfData: Self.fixture(order: order))
                let imported = Self.chords(score)
                try #require(!imported.isEmpty, "\(order)")
                for pitches in imported {
                    // `ChordNotes` dedups by pitch, so equal neighbours are
                    // impossible and the comparison can be strict — which
                    // makes this a check on the dedup as well as the order.
                    #expect(pitches == pitches.sorted(), "\(order): \(pitches)")
                    #expect(Set(pitches).count == pitches.count, "\(order): \(pitches)")
                }
            }
        }

        /// The multi-note chord really is being built — otherwise the two
        /// tests above would pass vacuously on a fixture that produced three
        /// separate one-note chords.
        @Test(.enabled(if: bravuraAvailable))
        func theFixtureProducesOneChordOfThreeNotes() throws {
            let score = try PDFImporter.parse(pdfData: Self.fixture(order: [0, 1, 2]))
            let imported = Self.chords(score)
            #expect(imported.contains { $0.count == 3 }, "\(imported)")
        }

        /// The convention this importer now follows, pinned against the
        /// repository's own MuseScore fixtures rather than asserted from
        /// memory: a chord read out of a real `.mscx` already ascends.
        @Test func parserAgreesThatChordNotesAscend() throws {
            let dir = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Resources")
            let names = try FileManager.default
                .contentsOfDirectory(atPath: dir.path)
                .filter { $0.hasSuffix(".mscx") }
                .sorted()
            var multiNoteChords = 0
            for name in names {
                guard let score = try? MSCXParser.parse(
                    contentsOf: dir.appendingPathComponent(name),
                ) else { continue }
                for part in score.parts {
                    for staff in part.staves {
                        for measure in staff.measures {
                            for voice in measure.voices {
                                for element in voice.elements {
                                    guard case let .chord(chord) = element,
                                          chord.notes.count > 1 else { continue }
                                    multiNoteChords += 1
                                    let pitches = chord.notes.map(\.pitch)
                                    #expect(pitches == pitches.sorted(), "\(name): \(pitches)")
                                }
                            }
                        }
                    }
                }
            }
            // A vacuous pass would mean the fixtures hold no chords at all.
            #expect(multiNoteChords >= 8, "only \(multiNoteChords) multi-note chords found")
        }
    }
#endif
