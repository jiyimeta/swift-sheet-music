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
    @Suite("EditGeometryBridge")
    struct EditGeometryBridgeTests {
        private let _installApple = TestSupport.installApple

        private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
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

        /// Encodes `LayoutOptionsWire.verticalDefault` with `layoutMode` overridden to horizontal (1).
        /// `nativeEncodeDrawProgram` derives its single page's dimensions from the cached document's own
        /// extent (`document.size`) — exactly how `.horizontal`-mode computes its page size too (see
        /// `EditGeometryBridge.swift`'s doc comment) — so only this mode lets the byte-for-byte comparison
        /// tests below hold without relaying anything out.
        private static func horizontalOptionsBytes() -> Data {
            var wire = LayoutOptionsWire.verticalDefault
            wire.layoutMode = 1
            return wire.encodeToData()
        }

        private static func verticalOptionsBytes() -> Data {
            LayoutOptionsWire.verticalDefault.encodeToData()
        }

        // MARK: - nativeEditingHitTest

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

        // MARK: - nativeEditingCaretFrame

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

        // MARK: - nativeEncodeDrawProgram

        /// Would report if `nativeEncodeDrawProgram` returned empty `Data` unconditionally: fails, since it
        /// requires bytes equal to a known-non-empty `nativeComputeLayout` result.
        @Test("nativeEncodeDrawProgram with an empty selection matches nativeComputeLayout byte-for-byte")
        func encodeDrawProgramEmptySelectionMatchesComputeLayout() {
            let handle = scoreTable.insert(Self.noteScore())
            defer { scoreTable.release(handle); LayoutDocumentCache.release(handle) }
            let originalBytes = nativeComputeLayout(
                scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297,
                optionsBlob: Self.horizontalOptionsBytes(),
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

        // MARK: - EditCaretFrameCodec

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
