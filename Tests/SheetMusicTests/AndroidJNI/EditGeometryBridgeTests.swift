#if !os(Android)
    import Foundation
    @testable import SheetMusicAndroidJNI
    import SheetMusicCore
    import SheetMusicEditWire
    @testable import SheetMusicLayout
    import Testing

    /// Task 11: drives the three editing-geometry JNI entry points as plain Swift functions on the host — the
    /// same way `EditSessionBridgeTests` drives SP0's — via `nativeComputeLayout` to populate
    /// `LayoutDocumentCache`, then the entry point under test.
    ///
    /// Fixtures are hand-built `Score` values inserted directly into `scoreTable` (`scoreTable.insert(_:)`,
    /// visible via `@testable import`) rather than round-tripped through `nativeLoadScore`'s MusicXML/MSCX
    /// parser: `nativeLoadScore` only accepts serialized bytes, and these tests need exact, known geometry
    /// (a specific notehead's coordinates, a specific tuplet's member IDs) the way `DrawProgramSelectionTests`
    /// (Task 10) does for `LayoutBridge.buildCommands` directly. Every other step — `nativeComputeLayout`,
    /// `nativeEditingHitTest`, `nativeEditingCaretFrame`, `nativeEncodeDrawProgram` — goes through the real
    /// bridge functions, not a shortcut.
    ///
    /// Split into per-entry-point extensions (`type_body_length` on the primary declaration only counts
    /// stored properties and fixtures below; each extension's own tests are counted separately).
    @Suite("EditGeometryBridge")
    struct EditGeometryBridgeTests {
        private let _installApple = TestSupport.installApple

        private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        private static let staff1 = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        private static let ptToMM = 25.4 / 72.0
        private static let tintArgb: UInt32 = 0xFFAB_CDEF

        // MARK: - Fixtures

        /// One measure, 4/4: a quarter chord (C4, element index 1) followed by three quarter rests.
        private static func noteScore() -> Score {
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
                .rest(duration: .quarter),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        private static let noteScoreNoteID = NoteID(
            staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
        )

        /// One measure, 4/4: a triplet of quarter-time chords (C4, D4, E4) followed by three quarter rests —
        /// same shape `DrawProgramSelectionTests.tripletScore()` uses, reproduced here so this file doesn't
        /// depend on that file's private fixture.
        private static func tripletScore() -> Score {
            let third = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))
            let voice = Voice(
                elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(Chord(duration: third, notes: [Note(pitch: 60, tpc: 14)])),
                    .chord(Chord(duration: third, notes: [Note(pitch: 62, tpc: 16)])),
                    .chord(Chord(duration: third, notes: [Note(pitch: 64, tpc: 18)])),
                    .rest(duration: .quarter),
                    .rest(duration: .quarter),
                    .rest(duration: .quarter),
                ],
                tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)],
            )
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        private static let tripletID = TupletID(staff: staff0, measureIndex: 0, voiceIndex: 0, startElementIndex: 1)

        /// Two measures, the first with `lineBreak: true` — guarantees exactly 2 systems regardless of page
        /// width, which `.page`-mode pagination tests need to force a genuine multi-page split (a 1-system
        /// score always fits on 1 page no matter how short `pageHeightMM` is, since `LayoutPaginator` never
        /// splits a system across pages).
        private static func twoSystemScore() -> Score {
            let measure0 = Measure(
                voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
                ])],
                lineBreak: true,
            )
            let measure1 = Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .whole, notes: [Note(pitch: 62, tpc: 16)])),
            ])])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [measure0, measure1])],
                )],
            )
        }

        private static let twoSystemMeasure1NoteID = NoteID(
            staff: staff0, measureIndex: 1, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
        )

        /// Two staves, one part: staff 0 carries a plain quarter note, staff 1 carries the same. Used with
        /// `hiddenStaff0OptionsBytes()` so a full-score address on staff 1 must be re-addressed past the
        /// hidden staff 0 to resolve against the filtered (1-staff) cached document.
        private static func twoStaffScore() -> Score {
            let voice = { () -> Voice in
                Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                    .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
                ])
            }
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [
                        Staff(measures: [Measure(voices: [voice()])]),
                        Staff(measures: [Measure(voices: [voice()])]),
                    ],
                )],
            )
        }

        private static let twoStaffStaff1NoteID = NoteID(
            staff: staff1, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
        )

        /// Two staves, one part: staff 0 (to be hidden) carries the triplet; staff 1 carries a plain note so
        /// the score isn't entirely hidden away. Used to prove a selection id whose staff is hidden is
        /// dropped from the tint rather than mismatched against the filtered document.
        private static func tripletOnHiddenStaffScore() -> Score {
            let third = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))
            let hiddenVoice = Voice(
                elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(Chord(duration: third, notes: [Note(pitch: 60, tpc: 14)])),
                    .chord(Chord(duration: third, notes: [Note(pitch: 62, tpc: 16)])),
                    .chord(Chord(duration: third, notes: [Note(pitch: 64, tpc: 18)])),
                    .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
                ],
                tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)],
            )
            let visibleVoice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: [Note(pitch: 48, tpc: 14)])),
                .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .quarter),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1", instrument: Instrument(id: "x"),
                    staves: [
                        Staff(measures: [Measure(voices: [hiddenVoice])]),
                        Staff(measures: [Measure(voices: [visibleVoice])]),
                    ],
                )],
            )
        }

        private static let hiddenTripletID = TupletID(
            staff: staff0, measureIndex: 0, voiceIndex: 0, startElementIndex: 1,
        )

        private static func verticalOptionsBytes() -> Data {
            LayoutOptionsWire.verticalDefault.encodeToData()
        }

        private static func horizontalOptionsBytes() -> Data {
            var wire = LayoutOptionsWire.verticalDefault
            wire.layoutMode = 1
            return wire.encodeToData()
        }

        private static func pageOptionsBytes() -> Data {
            var wire = LayoutOptionsWire.verticalDefault
            wire.layoutMode = 2
            return wire.encodeToData()
        }

        private static func hiddenStaff0OptionsBytes() -> Data {
            var wire = LayoutOptionsWire.verticalDefault
            wire.hiddenStaves = [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)]
            return wire.encodeToData()
        }
    }

    // MARK: - nativeEditingHitTest

    extension EditGeometryBridgeTests {
        /// Would report if `nativeEditingHitTest` returned empty `Data` unconditionally: fails, since it
        /// requires a non-empty, successfully-decoded `ScoreItemID` matching the real notehead.
        @Test("nativeEditingHitTest at a known notehead's mm coordinates decodes to that note's ScoreItemID")
        @available(macOS 15.0, iOS 16.0, *)
        func hitTestFindsNotehead() throws {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            let optionsBytes = Self.verticalOptionsBytes()
            let layoutBytes = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: optionsBytes,
            )
            #expect(!layoutBytes.isEmpty)

            let document = try #require(LayoutDocumentCache.value(for: handle))
            let system = try #require(document.systems.first)
            let measure = try #require(system.measures.first)
            let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)

            var anchor: CGPoint?
            for element in measure.elements {
                guard case let .chord(notes, _, stem, _, _, _, _, _, _, _, _) = element, let note = notes.first
                else { continue }
                anchor = CGPoint(
                    x: base.x + note.origin.x + note.mirrorDx(stem: stem, sp: system.sp),
                    y: base.y + note.origin.y,
                )
                break
            }
            let tapPoint = try #require(anchor)

            let result = nativeEditingHitTest(
                scoreHandle: handle,
                xMm: Double(tapPoint.x) * Self.ptToMM,
                yMm: Double(tapPoint.y) * Self.ptToMM,
                activeVoice: 0,
                optionsBytes: optionsBytes,
            )
            let decoded = try ScoreItemIDCodec.decode(result)
            #expect(decoded == .note(Self.noteScoreNoteID))
        }

        /// A probe far above every system — the same "empty page margin" case
        /// `LayoutDocumentEditingHitTestTests` uses for `editingHitTest` itself. Distinguishes "genuinely
        /// found nothing" from a hit-test whose probe accidentally lands on something; `hitTestFindsNotehead`
        /// above is what actually catches an always-empty mutant.
        @Test("nativeEditingHitTest at a point far from any staff returns empty Data")
        @available(macOS 15.0, iOS 16.0, *)
        func hitTestMiss() {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            let optionsBytes = Self.verticalOptionsBytes()
            _ = nativeComputeLayout(scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: optionsBytes)

            let result = nativeEditingHitTest(
                scoreHandle: handle, xMm: 0, yMm: -500 * Self.ptToMM, activeVoice: 0, optionsBytes: optionsBytes,
            )
            #expect(result.isEmpty)
        }

        @Test("nativeEditingHitTest with an unknown handle returns empty Data")
        func hitTestUnknownHandle() {
            let result = nativeEditingHitTest(
                scoreHandle: 999_999, xMm: 0, yMm: 0, activeVoice: 0, optionsBytes: Self.verticalOptionsBytes(),
            )
            #expect(result.isEmpty)
        }

        @Test("nativeEditingHitTest before nativeComputeLayout returns empty Data (nothing cached)")
        func hitTestBeforeComputeLayout() {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle) }
            let result = nativeEditingHitTest(
                scoreHandle: handle, xMm: 0, yMm: 0, activeVoice: 0, optionsBytes: Self.verticalOptionsBytes(),
            )
            #expect(result.isEmpty)
        }

        @Test("nativeEditingHitTest with undecodable options bytes returns empty Data")
        func hitTestGarbageOptions() {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            _ = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: Self.verticalOptionsBytes(),
            )
            let result = nativeEditingHitTest(
                scoreHandle: handle, xMm: 0, yMm: 0, activeVoice: 0, optionsBytes: Data([0xFF]),
            )
            #expect(result.isEmpty)
        }
    }

    // MARK: - nativeEditingCaretFrame

    extension EditGeometryBridgeTests {
        /// Would report if `nativeEditingCaretFrame` returned empty `Data` unconditionally: fails, since it
        /// requires a non-empty, decodable rect whose height matches `6 * sp` exactly.
        @Test("nativeEditingCaretFrame for an item returns a rect whose height is 6 * sp in mm")
        func caretFrameHeight() throws {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            _ = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: Self.verticalOptionsBytes(),
            )
            let document = try #require(LayoutDocumentCache.value(for: handle))
            let sp = document.metrics.sp

            let itemBytes = ScoreItemIDCodec.encode(.note(Self.noteScoreNoteID))
            let result = nativeEditingCaretFrame(scoreHandle: handle, itemBytes: itemBytes, minimumWidthMm: 0)
            let wire = try EditCaretFrameCodec.decode(result)
            #expect(abs(wire.heightMm - Double(6 * sp) * Self.ptToMM) < 0.0001)
        }

        /// `caretFrameHeight` above only checks `heightMm`. This covers the other three: `xMm`/`widthMm`
        /// against an independently-computed `cursorFrame`, so a mutant that dropped `* ptToMM` on x/y/width,
        /// swapped `xMm`/`yMm`, or hardcoded a component would fail here even though it would still pass
        /// `caretFrameHeight`; and `minimumWidthMm` with a generous floor, so a mutant that dropped
        /// `* mmToPt` on `minimumWidthMm` or ignored the parameter entirely would also fail (the un-floored
        /// natural width is far narrower than one notehead-sized glyph, let alone `bigFloorMm`).
        @Test("nativeEditingCaretFrame threads x/width from cursorFrame and floors width by minimumWidthMm")
        func caretFrameXWidthAndFloor() throws {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            _ = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: Self.verticalOptionsBytes(),
            )
            let document = try #require(LayoutDocumentCache.value(for: handle))
            let expectedFrame = try #require(
                document.cursorFrame(for: .item(.note(Self.noteScoreNoteID)), in: Self.noteScore()),
            )
            let itemBytes = ScoreItemIDCodec.encode(.note(Self.noteScoreNoteID))

            // No floor: xMm/widthMm match cursorFrame's own (un-floored) values.
            let unfloored = try EditCaretFrameCodec.decode(
                nativeEditingCaretFrame(scoreHandle: handle, itemBytes: itemBytes, minimumWidthMm: 0),
            )
            #expect(abs(unfloored.xMm - Double(expectedFrame.minX) * Self.ptToMM) < 0.0001)
            #expect(abs(unfloored.widthMm - Double(expectedFrame.width) * Self.ptToMM) < 0.0001)

            // A floor far wider than the natural frame forces widthMm up to (approximately) the floor value —
            // observable flooring, not just "some non-zero width".
            let bigFloorMm = 50.0
            #expect(unfloored.widthMm < bigFloorMm)
            let floored = try EditCaretFrameCodec.decode(
                nativeEditingCaretFrame(scoreHandle: handle, itemBytes: itemBytes, minimumWidthMm: bigFloorMm),
            )
            #expect(abs(floored.widthMm - bigFloorMm) < 0.01)
        }

        /// Hidden-staff coverage: `twoStaffScore()`'s selectable note lives on staff 1 in the FULL (unfiltered)
        /// score, but staff 0 is hidden via `hiddenStaff0OptionsBytes()`, so the cached document only has ONE
        /// staff — the formerly-staff-1 content, now at filtered index 0. `itemBytes` carries the full-score
        /// address (staff 1, the same convention `nativeEditingHitTest` returns), so this only resolves if
        /// `Score.translateCursorForHiddenStaves` correctly re-addresses staff 1 → filtered staff 0 before the
        /// `editingCaretRect` lookup. A missing or wrong-direction translation would look up filtered staff 1
        /// against a document that only has filtered staff 0, resolve nothing, and return empty `Data`.
        @Test("nativeEditingCaretFrame resolves a full-score item on a staff after a hidden earlier staff")
        func caretFrameTranslatesPastHiddenStaff() throws {
            let handle = scoreTable.insert(Self.twoStaffScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            _ = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297,
                optionsBlob: Self.hiddenStaff0OptionsBytes(),
            )

            let itemBytes = ScoreItemIDCodec.encode(.note(Self.twoStaffStaff1NoteID))
            let result = nativeEditingCaretFrame(scoreHandle: handle, itemBytes: itemBytes, minimumWidthMm: 0)
            let wire = try EditCaretFrameCodec.decode(result)
            #expect(wire.heightMm > 0)
            #expect(wire.widthMm > 0)
        }

        @Test("nativeEditingCaretFrame with an unknown handle returns empty Data")
        func caretFrameUnknownHandle() {
            let itemBytes = ScoreItemIDCodec.encode(.note(Self.noteScoreNoteID))
            let result = nativeEditingCaretFrame(scoreHandle: 999_999, itemBytes: itemBytes, minimumWidthMm: 0)
            #expect(result.isEmpty)
        }

        @Test("nativeEditingCaretFrame before nativeComputeLayout returns empty Data (nothing cached)")
        func caretFrameBeforeComputeLayout() {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle) }
            let itemBytes = ScoreItemIDCodec.encode(.note(Self.noteScoreNoteID))
            let result = nativeEditingCaretFrame(scoreHandle: handle, itemBytes: itemBytes, minimumWidthMm: 0)
            #expect(result.isEmpty)
        }

        @Test("nativeEditingCaretFrame with undecodable item bytes returns empty Data")
        func caretFrameGarbageBytes() {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            _ = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: Self.verticalOptionsBytes(),
            )
            let result = nativeEditingCaretFrame(
                scoreHandle: handle, itemBytes: Data([0xFF, 0x00]), minimumWidthMm: 0,
            )
            #expect(result.isEmpty)
        }
    }

    // MARK: - nativeEncodeDrawProgram

    extension EditGeometryBridgeTests {
        /// Would report if `nativeEncodeDrawProgram` returned empty `Data` unconditionally: fails, since it
        /// requires bytes equal to a known-non-empty `nativeComputeLayout` result. Run in all three layout
        /// modes — `LayoutDocumentCache.Entry` now carries the `LayoutOptionsWire` and page dimensions
        /// `nativeComputeLayout` was called with, so the re-encode must reproduce them all, not only
        /// `.horizontal` (the one mode whose page size happens to be recoverable from `document.size` alone).
        @Test("nativeEncodeDrawProgram with an empty selection matches nativeComputeLayout byte-for-byte (vertical)")
        func encodeDrawProgramEmptySelectionMatchesComputeLayoutVertical() {
            assertEmptySelectionMatchesComputeLayout(
                score: Self.noteScore(), optionsBytes: Self.verticalOptionsBytes(),
                pageWidthMM: 210, pageHeightMM: 297,
            )
        }

        @Test("nativeEncodeDrawProgram with an empty selection matches nativeComputeLayout byte-for-byte (horizontal)")
        func encodeDrawProgramEmptySelectionMatchesComputeLayoutHorizontal() {
            assertEmptySelectionMatchesComputeLayout(
                score: Self.noteScore(), optionsBytes: Self.horizontalOptionsBytes(),
                pageWidthMM: 210, pageHeightMM: 297,
            )
        }

        /// `.page` mode specifically: `twoSystemScore()` forces exactly 2 systems, and `pageHeightMM` is
        /// picked (from the FIRST, throwaway `nativeComputeLayout` call's own cached document) to fit system 0
        /// alone but not both — so the untinted `nativeComputeLayout` this compares against is genuinely a
        /// 2-page program, the case Task 11's original review found collapsed to 1 page by the pre-fix
        /// `nativeEncodeDrawProgram`, which always emitted a single page from the continuous document.
        @Test("nativeEncodeDrawProgram with an empty selection matches nativeComputeLayout byte-for-byte (page)")
        func encodeDrawProgramEmptySelectionMatchesComputeLayoutPage() throws {
            let probeHandle = scoreTable.insert(Self.twoSystemScore())
            _ = nativeComputeLayout(
                scoreHandle: probeHandle, pageWidthMM: 210, pageHeightMM: 1000, optionsBlob: Self.pageOptionsBytes(),
            )
            let probeDocument = try #require(LayoutDocumentCache.value(for: probeHandle))
            #expect(probeDocument.systems.count == 2)
            let system0Bottom = probeDocument.systems[0].origin.y + probeDocument.systems[0].size.height
            let pageHeightMM = Double(system0Bottom) * Self.ptToMM + 2
            scoreTable.release(probeHandle)
            LayoutDocumentCache.release(probeHandle)

            let handle = scoreTable.insert(Self.twoSystemScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            let originalBytes = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: pageHeightMM,
                optionsBlob: Self.pageOptionsBytes(),
            )
            let originalPages = try DrawProgramCodec.decode(originalBytes)
            #expect(originalPages.count == 2)

            let emptySelectionBytes = SelectionTintCodec.encode(argb: Self.tintArgb, ids: [])
            let reencoded = nativeEncodeDrawProgram(scoreHandle: handle, selectionBytes: emptySelectionBytes)
            #expect(reencoded == originalBytes)
        }

        /// `.page` mode with a real (non-empty) selection: proves a tuplet-free note on the SECOND page still
        /// tints correctly through `encodePages`' per-page `buildCommands(layout:tint:)` call, and that the
        /// page count survives tinting (2 pages in, 2 pages out).
        @Test("nativeEncodeDrawProgram with a note selected on page 2 differs, same page count (page mode)")
        func encodeDrawProgramTintedSelectionDiffersPageMode() throws {
            let probeHandle = scoreTable.insert(Self.twoSystemScore())
            _ = nativeComputeLayout(
                scoreHandle: probeHandle, pageWidthMM: 210, pageHeightMM: 1000, optionsBlob: Self.pageOptionsBytes(),
            )
            let probeDocument = try #require(LayoutDocumentCache.value(for: probeHandle))
            let system0Bottom = probeDocument.systems[0].origin.y + probeDocument.systems[0].size.height
            let pageHeightMM = Double(system0Bottom) * Self.ptToMM + 2
            scoreTable.release(probeHandle)
            LayoutDocumentCache.release(probeHandle)

            let handle = scoreTable.insert(Self.twoSystemScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            let originalBytes = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: pageHeightMM,
                optionsBlob: Self.pageOptionsBytes(),
            )
            let originalPages = try DrawProgramCodec.decode(originalBytes)
            #expect(originalPages.count == 2)

            let selectionBytes = SelectionTintCodec.encode(
                argb: Self.tintArgb, ids: [.note(Self.twoSystemMeasure1NoteID)],
            )
            let tintedBytes = nativeEncodeDrawProgram(scoreHandle: handle, selectionBytes: selectionBytes)
            let tintedPages = try #require(try? DrawProgramCodec.decode(tintedBytes))

            #expect(tintedBytes != originalBytes)
            #expect(tintedPages.count == originalPages.count)
            let brackets = tintedPages.flatMap(\.commands).filter {
                if case let .setColor(a) = $0 { return a == Self.tintArgb }
                return false
            }
            #expect(!brackets.isEmpty)
        }

        private func assertEmptySelectionMatchesComputeLayout(
            score: Score, optionsBytes: Data, pageWidthMM: Double, pageHeightMM: Double,
        ) {
            let handle = scoreTable.insert(score)
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            let originalBytes = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM,
                optionsBlob: optionsBytes,
            )
            #expect(!originalBytes.isEmpty)

            let emptySelectionBytes = SelectionTintCodec.encode(argb: Self.tintArgb, ids: [])
            let reencoded = nativeEncodeDrawProgram(scoreHandle: handle, selectionBytes: emptySelectionBytes)
            #expect(reencoded == originalBytes)
        }

        /// Would report if `nativeEncodeDrawProgram` returned empty `Data` unconditionally: fails both
        /// `#expect`s (an empty `Data` is neither `!= originalBytes` in the interesting sense — it trivially
        /// differs, but `DrawProgramCodec.decode` on empty bytes throws, which `#require` below turns into a
        /// test failure rather than a false pass).
        @Test("nativeEncodeDrawProgram with a note selected differs from the untinted bytes, same page count")
        func encodeDrawProgramTintedSelectionDiffers() throws {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            let originalBytes = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297,
                optionsBlob: Self.horizontalOptionsBytes(),
            )
            let originalPages = try DrawProgramCodec.decode(originalBytes)

            let selectionBytes = SelectionTintCodec.encode(argb: Self.tintArgb, ids: [.note(Self.noteScoreNoteID)])
            let tintedBytes = nativeEncodeDrawProgram(scoreHandle: handle, selectionBytes: selectionBytes)
            let tintedPages = try #require(try? DrawProgramCodec.decode(tintedBytes))

            #expect(tintedBytes != originalBytes)
            #expect(tintedPages.count == originalPages.count)
        }

        /// The test that proves `SelectionExpansion` is on the path, not just present in the codebase: the
        /// input selection carries ONLY the tuplet's own `ScoreItemID` (never pre-expanded by this test, unlike
        /// `DrawProgramSelectionTests.tupletSelectionTintsItsMembers`, which hands `LayoutBridge.buildCommands`
        /// an already-expanded set). If `nativeEncodeDrawProgram` skipped expansion and passed the decoded
        /// `ids` straight through, only the tuplet bracket would tint and this would read 1, not 4.
        @Test("nativeEncodeDrawProgram expands a tuplet selection to its members")
        func encodeDrawProgramExpandsTuplet() throws {
            let handle = scoreTable.insert(Self.tripletScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            _ = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297,
                optionsBlob: Self.verticalOptionsBytes(),
            )

            let selectionBytes = SelectionTintCodec.encode(argb: Self.tintArgb, ids: [.tuplet(Self.tripletID)])
            let result = nativeEncodeDrawProgram(scoreHandle: handle, selectionBytes: selectionBytes)
            let pages = try DrawProgramCodec.decode(result)

            let brackets = pages.flatMap(\.commands).filter {
                if case let .setColor(a) = $0 { return a == Self.tintArgb }
                return false
            }
            #expect(brackets.count == 4)
        }

        @Test("nativeEncodeDrawProgram with an unknown handle returns empty Data")
        func encodeDrawProgramUnknownHandle() {
            let selectionBytes = SelectionTintCodec.encode(argb: Self.tintArgb, ids: [])
            let result = nativeEncodeDrawProgram(scoreHandle: 999_999, selectionBytes: selectionBytes)
            #expect(result.isEmpty)
        }

        @Test("nativeEncodeDrawProgram before nativeComputeLayout returns empty Data (nothing cached, never relayouts)")
        func encodeDrawProgramBeforeComputeLayout() {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle) }
            let selectionBytes = SelectionTintCodec.encode(argb: Self.tintArgb, ids: [])
            let result = nativeEncodeDrawProgram(scoreHandle: handle, selectionBytes: selectionBytes)
            #expect(result.isEmpty)
        }

        @Test("nativeEncodeDrawProgram with undecodable selection bytes returns empty Data")
        func encodeDrawProgramGarbageBytes() {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            _ = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297,
                optionsBlob: Self.verticalOptionsBytes(),
            )
            let result = nativeEncodeDrawProgram(scoreHandle: handle, selectionBytes: Data([0xFF, 0x00]))
            #expect(result.isEmpty)
        }

        /// Hidden-staff coverage: `tripletOnHiddenStaffScore()`'s tuplet lives on staff 0, hidden via
        /// `hiddenStaff0OptionsBytes()`. The selection id is dropped (not merely left untinted for some other
        /// reason) — either because `Score.translateCursorForHiddenStaves` resolves it to a `.beat` fallback
        /// (dropped by `nativeEncodeDrawProgram`'s own `guard case .item`), or because it survives as `.item`
        /// but with a staff address the filtered document has no elements under, so `SelectionExpansion.expand`
        /// falls back to `[id]` and `LayoutBridge.tintColor` never matches it — either path proves the same
        /// thing: an id on a hidden staff can never light up a `.setColor` bracket. A wrong-direction
        /// translation (`filterStaffAddress` swapped for `unfilterStaffAddress`, or vice versa) would either
        /// crash resolving `SelectionExpansion.expand` against the wrong score, or, if it happened to resolve
        /// anyway, would tint SOME bracket — so `brackets.isEmpty` is a real assertion, not a vacuous one.
        @Test("nativeEncodeDrawProgram drops a selection id whose staff is hidden")
        func encodeDrawProgramDropsHiddenStaffSelection() throws {
            let handle = scoreTable.insert(Self.tripletOnHiddenStaffScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            _ = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297,
                optionsBlob: Self.hiddenStaff0OptionsBytes(),
            )

            let selectionBytes = SelectionTintCodec.encode(argb: Self.tintArgb, ids: [.tuplet(Self.hiddenTripletID)])
            let result = nativeEncodeDrawProgram(scoreHandle: handle, selectionBytes: selectionBytes)
            let pages = try DrawProgramCodec.decode(result)

            let brackets = pages.flatMap(\.commands).filter {
                if case let .setColor(a) = $0 { return a == Self.tintArgb }
                return false
            }
            #expect(brackets.isEmpty)
        }
    }

    // MARK: - EditCaretFrameCodec

    extension EditGeometryBridgeTests {
        @Test("EditCaretFrameCodec round-trips xMm/yMm/widthMm/heightMm")
        func editCaretFrameCodecRoundTrips() throws {
            let data = EditCaretFrameCodec.encode(xMm: 1.5, yMm: -2.25, widthMm: 3.75, heightMm: 4.125)
            let wire = try EditCaretFrameCodec.decode(data)
            #expect(wire.xMm == 1.5)
            #expect(wire.yMm == -2.25)
            #expect(wire.widthMm == 3.75)
            #expect(wire.heightMm == 4.125)
        }
    }
#endif
