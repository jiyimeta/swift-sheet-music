#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// Lyrics that sit on a chord whose stem (and optional flag) pokes
    /// below the staff used to land on top of the stem because the
    /// placement only considered the lowest notehead's Y. The fix
    /// extends the per-chord south to include stem-down stem ends and
    /// flag glyph height — mirroring the south-skyline contribution
    /// MuseScore's `LyricsLayout::computeVerticalOffset` consults.
    @Suite("LayoutEngine — lyric vs stem/flag")
    struct LyricStemAvoidanceTests {
        private let _installApple = TestSupport.installApple

        /// Stem-down chord whose stem+flag extends well past the
        /// staff bottom: lyric must sit below stem-end + flag with a
        /// small clearance, not over them.
        @Test("Stem-down 8th's flag does not collide with the lyric")
        func lyricClearsStemDownEighthFlag() {
            guard #available(macOS 15.0, *) else { return }
            // Wide-spread chord: D4 + G5 + A5. Median is positive
            // so stems are forced down; the lowest note D4 sits well
            // below the staff middle, so the stem-down stem extends
            // far past the staff bottom (and past the default lyric
            // base floor of `staffMidY + 4 sp`). With an 8th flag,
            // the visual south reaches further still — the case the
            // user reported as overlapping.
            let chord = Chord(
                duration: .eighth,
                notes: ChordNotes([
                    Note(pitch: 62, tpc: 16), // D4
                    Note(pitch: 79, tpc: 18), // G5
                    Note(pitch: 81, tpc: 20), // A5
                ]),
                lyrics: [Lyric(text: "ah", syllabic: .single)],
            )
            let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
            let staff = Staff(measures: [measure])
            let part = Part(
                id: "1", instrument: Instrument(id: "voice"),
                staves: [staff],
            )
            let score = Score(division: 480, parts: [part])

            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            var lyricEl: LayoutElement?
            var chordEl: LayoutElement?
            for system in doc.systems {
                for measure in system.measures {
                    for el in measure.elements {
                        switch el {
                        case .textMark(.lyrics, _, _) where lyricEl == nil:
                            lyricEl = el
                        case .chord where chordEl == nil:
                            chordEl = el
                        default:
                            break
                        }
                    }
                }
            }
            guard let lyricEl, let chordEl else {
                Issue.record("Missing lyric or chord layout element")
                return
            }
            guard case let .textMark(_, _, lyricOrigin) = lyricEl,
                  case let .chord(notes, _, stem, _, _, _, _, _) = chordEl
            else {
                Issue.record("Unexpected LayoutElement shape")
                return
            }
            #expect(stem == .down)

            // Stem geometry matches StemRenderer: stem-down extends
            // from the highest note (yTop) down to lowestNoteY +
            // defaultStemLength. Use the layout-supplied options
            // staffSize=28 → sp=7 (StaffMetrics default).
            let sp: CGFloat = 7
            let noteYs = notes.map(\.origin.y)
            let yBot = noteYs.max() ?? 0
            let stemEnd = yBot + sp * 3.5
            // Conservative 8th-flag glyph allowance: ~1.5 sp tall.
            let flagBottom = stemEnd + sp * 1.5
            let message = "Lyric center y=\(lyricOrigin.y) sits above the 8th flag bottom y=\(flagBottom)"
            #expect(
                lyricOrigin.y >= flagBottom,
                Comment(rawValue: message),
            )
        }

        /// Stem-down chord whose stem+flag only barely passes the
        /// staff bottom: lyric should sit close to the default base
        /// floor with MuseScore's tight 0.25 sp minDistance, not
        /// pushed an extra full sp away.
        @Test("Barely-protruding stem/flag does not push lyric down excessively")
        func lyricClearanceIsTightWhenFlagBarelyProtrudes() {
            guard #available(macOS 15.0, *) else { return }
            // F5 (step 4 in treble) — stem-down. Stem-end at noteY +
            // 3.5 sp lands ~1 sp past the staff bottom; 8th flag adds
            // ~1 sp more, so the obstacle pokes ~2 sp past the staff.
            // MuseScore would shift the lyric only ~0.35 sp from the
            // default base floor; an over-padded fix shifts it 1+ sp.
            let chord = Chord(
                duration: .eighth,
                notes: ChordNotes([Note(pitch: 77, tpc: 13)]), // F5
                lyrics: [Lyric(text: "ah", syllabic: .single)],
            )
            let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
            let staff = Staff(measures: [measure])
            let part = Part(
                id: "1", instrument: Instrument(id: "voice"),
                staves: [staff],
            )
            let score = Score(division: 480, parts: [part])

            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            var lyricEl: LayoutElement?
            var chordEl: LayoutElement?
            for system in doc.systems {
                for measure in system.measures {
                    for el in measure.elements {
                        switch el {
                        case .textMark(.lyrics, _, _) where lyricEl == nil:
                            lyricEl = el
                        case .chord where chordEl == nil:
                            chordEl = el
                        default:
                            break
                        }
                    }
                }
            }
            guard let lyricEl, let chordEl else {
                Issue.record("Missing lyric or chord layout element")
                return
            }
            guard case let .textMark(_, _, lyricOrigin) = lyricEl,
                  case let .chord(notes, _, stem, _, _, _, _, _) = chordEl
            else {
                Issue.record("Unexpected LayoutElement shape")
                return
            }
            #expect(stem == .down)

            let sp: CGFloat = 7
            let noteY = notes[0].origin.y
            // For F5 (step 4), staffMidY_translated = noteY + 2 sp,
            // so baseFloor (staffMidY + 4 sp) = noteY + 6 sp. With
            // MuseScore's 0.25 sp minDistance, the tightest correct
            // lyric center sits ~0.35 sp below baseFloor (the flag
            // tip's contribution) — comfortably under noteY + 6.7 sp.
            // The over-padded "always 2.1 sp above the obstacle"
            // formulation yields noteY + 7.1 sp, which this bound
            // catches.
            let upperBound = noteY + sp * 6.7
            let message = "Lyric center y=\(lyricOrigin.y) overshoots the base floor (upperBound \(upperBound))"
            #expect(
                lyricOrigin.y < upperBound,
                Comment(rawValue: message),
            )
        }
    }
#endif
