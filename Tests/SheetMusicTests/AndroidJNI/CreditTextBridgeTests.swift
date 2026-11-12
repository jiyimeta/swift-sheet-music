#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    #if os(macOS)
        import CoreGraphics
        import Foundation
        @testable import SheetMusicAndroidJNI
        @testable import SheetMusicBridgeCore
        @testable import SheetMusicCore
        import SheetMusicEditWire
        @testable import SheetMusicLayout
        import Testing

        /// `nativeSelectionInkFrames` for a selected text, and `nativeCreditTextHit` / `nativeCreditTextFrame` — the
        /// geometry an Android host needs to hang a pill off an engraved text or a title-block credit. Every frame is
        /// the Apple host's own answer (`textHitRect(for:)`, `creditTextLine`) on the cached document, converted to
        /// millimetres.
        @Suite("Credit text bridge")
        struct CreditTextBridgeTests {
            private let _installApple = TestSupport.installApple

            private static let ptToMm = 25.4 / 72.0
            private static let mmToPt = 72.0 / 25.4
            private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            private static let lyricAnchor = VoiceElementID(
                staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 0,
            )

            /// One bar holding a whole note with the lyric "la", and a title frame carrying a title, a composer and
            /// nothing else — so the lyricist has no line.
            private static func score() -> Score {
                let chord = Chord(
                    duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]), lyrics: [Lyric(text: "la")],
                )
                let staff = Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])
                var score = Score(
                    division: 480,
                    parts: [Part(id: "1", instrument: Instrument(id: "voice"), staves: IdentifiedArray([staff]))],
                )
                score.titleFrame = ScoreFrame(heightSp: 10, texts: [
                    FrameText(style: .title, text: "Sonata"),
                    FrameText(style: .composer, text: "Anon."),
                ])
                return score
            }

            private static func laidOut(_ score: Score) -> Int64 {
                let handle = scoreTable.insert(score)
                _ = nativeComputeLayout(
                    scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297,
                    optionsBlob: LayoutOptionsWire.verticalDefault.encodeToData(),
                )
                return handle
            }

            private static func release(_ handle: Int64) {
                scoreTable.release(handle)
                LayoutDocumentCache.release(handle)
            }

            private static func expectMatches(_ frame: CreditTextFrameWire, _ rect: CGRect, sp: CGFloat) {
                #expect(abs(frame.spMm - Double(sp) * ptToMm) < 1e-9)
                #expect(abs(frame.xMm - Double(rect.minX) * ptToMm) < 1e-9)
                #expect(abs(frame.yMm - Double(rect.minY) * ptToMm) < 1e-9)
                #expect(abs(frame.widthMm - Double(rect.width) * ptToMm) < 1e-9)
                #expect(abs(frame.heightMm - Double(rect.height) * ptToMm) < 1e-9)
            }

            @Test func aSelectedLyricHasOneInkFrame() throws {
                guard #available(macOS 15.0, *) else { return }
                let handle = Self.laidOut(Self.score())
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                let id = ScoreTextID.lyric(anchor: Self.lyricAnchor, verse: 0)
                let tester = ScoreHitTester(document: document)
                let rect = try #require(tester.textHitRect(for: ScoreHitTarget(textID: id)))

                let wire = try SelectionInkFramesCodec.decode(
                    nativeSelectionInkFrames(scoreHandle: handle, itemBytes: ScoreItemIDCodec.encode(.text(id))),
                )

                #expect(wire.frames.count == 1)
                let frame = try #require(wire.frames.first)
                #expect(abs(frame.xMm - Double(rect.minX) * Self.ptToMm) < 1e-9)
                #expect(abs(frame.yMm - Double(rect.minY) * Self.ptToMm) < 1e-9)
                #expect(abs(frame.widthMm - Double(rect.width) * Self.ptToMm) < 1e-9)
                #expect(abs(frame.heightMm - Double(rect.height) * Self.ptToMm) < 1e-9)
            }

            @Test func theCreditHitFindsTheComposer() throws {
                let handle = Self.laidOut(Self.score())
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                let line = try #require(document.creditTextLine(for: .composer))

                let data = nativeCreditTextHit(
                    scoreHandle: handle,
                    xMm: Double(line.frame.midX) * Self.ptToMm,
                    yMm: Double(line.frame.midY) * Self.ptToMm,
                )

                let wire = try CreditTextFrameCodec.decode(data)
                #expect(wire.fieldCode == 2)
                Self.expectMatches(wire, line.frame, sp: document.metrics.sp)
            }

            @Test func aPointOffEveryCreditHitsNothing() {
                let handle = Self.laidOut(Self.score())
                defer { Self.release(handle) }

                #expect(nativeCreditTextHit(scoreHandle: handle, xMm: -100, yMm: -100).isEmpty)
                #expect(nativeCreditTextHit(scoreHandle: 987_654, xMm: 105, yMm: 20).isEmpty)
            }

            @Test func theCreditFrameForATitle() throws {
                let handle = Self.laidOut(Self.score())
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                let line = try #require(document.creditTextLine(for: .title))

                let wire = try CreditTextFrameCodec.decode(nativeCreditTextFrame(scoreHandle: handle, fieldCode: 0))

                #expect(wire.fieldCode == 0)
                Self.expectMatches(wire, line.frame, sp: document.metrics.sp)
            }

            @Test func anUnengravedFieldHasNoFrame() {
                let handle = Self.laidOut(Self.score())
                defer { Self.release(handle) }

                // 4 is the lyricist, which the score's title frame does not carry; 99 is outside the table.
                #expect(nativeCreditTextFrame(scoreHandle: handle, fieldCode: 4).isEmpty)
                #expect(nativeCreditTextFrame(scoreHandle: handle, fieldCode: 99).isEmpty)
                #expect(nativeCreditTextFrame(scoreHandle: handle, fieldCode: -1).isEmpty)
            }

            @Test func fieldCodesRoundTrip() throws {
                #expect(ScoreInfoWrite.Field.allCases.count == 6)
                for field in ScoreInfoWrite.Field.allCases {
                    let code = ScoreInfoFieldCode.code(of: field)
                    #expect(ScoreInfoFieldCode.field(code: code) == field)
                }
                #expect(ScoreInfoFieldCode.code(of: .title) == 0)
                #expect(ScoreInfoFieldCode.code(of: .copyright) == 5)
                #expect(ScoreInfoFieldCode.field(code: 6) == nil)

                let write = ScoreInfoWrite(field: .lyricist, text: "Trad.")
                let bytes = ScoreInfoWriteWire(from: write).encodeToData()
                #expect(try ScoreInfoWriteWire(decoding: bytes).decoded() == write)
            }
        }
    #endif
#endif
