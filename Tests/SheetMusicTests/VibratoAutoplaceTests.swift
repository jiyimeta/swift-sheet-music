#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("Vibrato autoplace")
    struct VibratoAutoplaceTests {
        /// Install the Apple CoreText font-metrics provider so layout
        /// produces real chord positions.
        private let _installApple = TestSupport.installApple

        // MARK: - Helpers

        /// Build a minimal single-staff score with a whole-measure vibrato
        /// spanner over one measure containing a single whole note.
        private static func makeScore(notePitch: Int, tpc: Int) -> Score {
            let note = Note(pitch: notePitch, tpc: tpc)
            let chord = Chord(duration: .whole, notes: [note])
            let vibrato = Spanner(
                kind: .vibrato,
                rawType: "Vibrato",
                nextMeasuresOffset: 0,
                vibrato: Spanner.VibratoPayload(type: .guitarVibrato),
            )
            let measure = Measure(voices: [Voice(elements: [
                .spanner(vibrato),
                .chord(chord),
            ])])
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

        /// Find the vibrato spannerSegment in a system.
        private static func vibratoY(in system: LayoutSystem) -> CGFloat? {
            for el in system.spanners {
                if case let .spannerSegment(.vibrato, fromOrigin, _, _, _, _) = el {
                    return fromOrigin.y
                }
            }
            return nil
        }

        // MARK: - chordNorthByTick population

        @Test("chordNorthByTick is populated for a measure with a chord")
        func chordNorthByTickPopulated() {
            guard #available(macOS 15.0, *) else { return }
            // C6 (MIDI 84) sits well above the treble staff.
            let score = Self.makeScore(notePitch: 84, tpc: 14)
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let measure = doc.systems.first?.measures.first
            #expect(measure != nil)
            if let m = measure {
                // The whole-note chord is at tick 0. The north map
                // must contain at least that entry.
                #expect(!m.chordNorthByTick.isEmpty)
                #expect(m.chordNorthByTick[0] != nil)
            }
        }

        // MARK: - Vibrato anchorY with high note

        @Test("High note (C6) pushes vibrato above default Y")
        func highNotePushesVibratoUp() {
            guard #available(macOS 15.0, *) else { return }
            // C6 (MIDI 84, tpc 14) has step = +8 in treble clef —
            // 8 diatonic steps above the middle line (B4), well above
            // the staff. Its system-level Y ≈ staffOrigins.y − 2*sp,
            // which is above the fixed default of staffOrigins.y − 1.5*sp.
            // Autoplace must push the vibrato up so it clears the note.
            let score = Self.makeScore(notePitch: 84, tpc: 14)
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            guard let system = doc.systems.first else {
                Issue.record("expected at least one system")
                return
            }
            guard let vibratoYValue = Self.vibratoY(in: system) else {
                Issue.record("expected a vibrato spannerSegment in system spanners")
                return
            }
            let sp = system.sp
            let staffOriginY = system.staffOrigins[0].y
            let defaultVibratoY = staffOriginY - sp * 1.5
            // Autoplace must have raised the vibrato above the default.
            #expect(
                vibratoYValue < defaultVibratoY,
                "vibrato Y \(vibratoYValue) should be above default \(defaultVibratoY) for C6",
            )
        }

        @Test("Low note (C4) leaves vibrato at default Y")
        func lowNoteVibratoAtDefaultY() {
            guard #available(macOS 15.0, *) else { return }
            // C4 (MIDI 60, middle C, step = -6 in treble clef) sits
            // well below the staff. The default vibrato Y is already
            // far above it; autoplace should leave it unchanged.
            let score = Self.makeScore(notePitch: 60, tpc: 14)
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            guard let system = doc.systems.first else {
                Issue.record("expected at least one system")
                return
            }
            guard let vibratoYValue = Self.vibratoY(in: system) else {
                Issue.record("expected a vibrato spannerSegment in system spanners")
                return
            }
            let sp = system.sp
            let staffOriginY = system.staffOrigins[0].y
            let defaultVibratoY = staffOriginY - sp * 1.5
            // Low note: vibrato must sit at exactly the default Y.
            #expect(
                abs(vibratoYValue - defaultVibratoY) < 0.5,
                "vibrato Y \(vibratoYValue) should equal default \(defaultVibratoY) for C4",
            )
        }

        @Test("High note vibrato Y satisfies clearance formula (anchorY + halfH + 1sp ≤ noteTop)")
        func highNoteExactClearanceFormula() {
            guard #available(macOS 15.0, *) else { return }
            // C6 triggers autoplace (its notehead top sits above the default
            // vibrato Y = staffOriginY − 1.5 sp).
            let score = Self.makeScore(notePitch: 84, tpc: 14) // C6
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            guard let system = doc.systems.first,
                  let measure = system.measures.first
            else {
                Issue.record("expected system and measure")
                return
            }
            guard let noteTop = measure.chordNorthByTick.values.min() else {
                Issue.record("expected chordNorthByTick to be populated")
                return
            }
            guard let vibratoY = Self.vibratoY(in: system) else {
                Issue.record("expected vibrato spannerSegment")
                return
            }
            let sp = system.sp

            // Glyph half-height for the vibrato type used in makeScore.
            let codepoint = SpannerGeometry.vibratoCodepoint(type: .guitarVibrato)
            let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: sp * 4)
            let halfH: CGFloat
            if let bbox = FontMetrics.provider.glyphPathBoundingBox(
                font: font, codepoint: UInt16(codepoint),
            ) {
                halfH = bbox.height / 2
            } else {
                halfH = sp * 0.5
            }

            // Formula: anchorY + halfH + 1.0*sp ≤ noteTop
            //   → anchorY = noteTop − 1.0*sp − halfH
            // C6 is above the default, so autoplace should land exactly on
            // the clearance value (min of default and clearance = clearance).
            let expectedY = noteTop - sp - halfH
            #expect(
                abs(vibratoY - expectedY) < 0.01,
                """
                vibrato anchorY \(vibratoY) should equal clearance formula \
                \(expectedY) (noteTop=\(noteTop), sp=\(sp), halfH=\(halfH))
                """,
            )
        }

        @Test("Vibrato Y for high note is strictly above vibrato Y for low note")
        func highNoteIsAboveLowNote() {
            guard #available(macOS 15.0, *) else { return }
            let highScore = Self.makeScore(notePitch: 84, tpc: 14) // C6
            let lowScore = Self.makeScore(notePitch: 60, tpc: 14) // C4
            let highDoc = LayoutEngine.layout(
                score: highScore, options: .init(), availableWidth: 800,
            )
            let lowDoc = LayoutEngine.layout(
                score: lowScore, options: .init(), availableWidth: 800,
            )
            guard let highSystem = highDoc.systems.first,
                  let lowSystem = lowDoc.systems.first
            else { return }
            guard let highY = Self.vibratoY(in: highSystem),
                  let lowY = Self.vibratoY(in: lowSystem)
            else {
                Issue.record("expected vibrato spannerSegments in both systems")
                return
            }
            // In Y-down coords, smaller Y = higher on screen.
            #expect(
                highY < lowY,
                "vibrato above C6 (\(highY)) must be higher than above C4 (\(lowY))",
            )
        }
    }
#endif
