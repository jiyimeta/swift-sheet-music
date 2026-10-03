#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    #if os(macOS)
        import CoreGraphics
        import Foundation
        @testable import SheetMusicAndroidJNI
        @testable import SheetMusicBridgeCore
        import SheetMusicCore
        import SheetMusicEditWire
        @testable import SheetMusicLayout
        import Testing

        /// `nativeEditingMeasureHitTest`: `LayoutDocument.editingMeasureHit(at:)` behind the JNI boundary, re-addressed
        /// past the cached layout's hidden staves the way `nativeEditingHitTest` is.
        @Suite("Edit measure-hit bridge")
        struct EditMeasureHitBridgeTests {
            private let _installApple = TestSupport.installApple
            private static let ptToMM = 25.4 / 72.0

            /// One part, two staves; each staff has bar 0 (meter + four quarter rests), bars 1–3 (a measure rest
            /// each, the run that collapses) and bar 4 (four quarter rests).
            private static func score() -> Score {
                let quarters: [VoiceElement] = Array(repeating: .rest(duration: .quarter), count: 4)
                let meter = VoiceElement.timeSignature(TimeSignature(numerator: 4, denominator: 4))
                let staff = Staff(measures: [
                    Measure(voices: [Voice(elements: [meter] + quarters)]),
                    Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
                    Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
                    Measure(voices: [Voice(elements: [.rest(duration: .measure)])]),
                    Measure(voices: [Voice(elements: quarters)]),
                ])
                return Score(
                    division: 480, parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff, staff])],
                )
            }

            private static func options(collapsing: Bool = false, hidingStaff0: Bool = false) -> Data {
                var wire = LayoutOptionsWire.verticalDefault
                wire.collapseMultiMeasureRests = collapsing ? 1 : 0
                wire.hiddenStaves = hidingStaff0 ? [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)] : []
                return wire.encodeToData()
            }

            private static func laidOut(_ options: Data) -> Int64 {
                let handle = scoreTable.insert(score())
                _ = nativeComputeLayout(scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: options)
                return handle
            }

            private static func release(_ handle: Int64) {
                scoreTable.release(handle)
                LayoutDocumentCache.release(handle)
            }

            /// Bar `index`'s centre on the middle line of the cached layout's row `row`, in document mm.
            private static func pointMm(bar index: Int, row: Int, in handle: Int64) throws -> (x: Double, y: Double) {
                let document = try #require(LayoutDocumentCache.value(for: handle))
                let system = try #require(document.systems.first { $0.measures.contains { $0.measureIndex == index } })
                let measure = try #require(system.measures.first { $0.measureIndex == index })
                let x = system.origin.x + measure.origin.x + measure.width / 2
                let y = system.origin.y + system.staffOrigins[row].y + 2 * document.metrics.sp
                return (Double(x) * ptToMM, Double(y) * ptToMM)
            }

            @Test func `a point inside a bar answers its staff and bar`() throws {
                let handle = Self.laidOut(Self.options())
                defer { Self.release(handle) }
                let point = try Self.pointMm(bar: 4, row: 1, in: handle)
                let hit = try EditMeasureHitCodec.decode(
                    nativeEditingMeasureHitTest(scoreHandle: handle, xMm: point.x, yMm: point.y),
                )
                #expect(hit.partIndex == 0)
                #expect(hit.staffIndexInPart == 1)
                #expect(hit.firstMeasureIndex == 4)
                #expect(hit.lastMeasureIndex == 4)
            }

            /// Staff 0 hidden: the cached layout's only row is full-score staff 1, and the answer has to say so. It
            /// becomes the staff an edit or a range is built on.
            @Test func `a hit below a hidden staff is re-addressed to the full score`() throws {
                let handle = Self.laidOut(Self.options(hidingStaff0: true))
                defer { Self.release(handle) }
                let point = try Self.pointMm(bar: 0, row: 0, in: handle)
                let hit = try EditMeasureHitCodec.decode(
                    nativeEditingMeasureHitTest(scoreHandle: handle, xMm: point.x, yMm: point.y),
                )
                #expect(hit.staffIndexInPart == 1)
                #expect(hit.firstMeasureIndex == 0)
            }

            @Test func `a collapsed multi-measure rest answers its whole run`() throws {
                let handle = Self.laidOut(Self.options(collapsing: true))
                defer { Self.release(handle) }
                let point = try Self.pointMm(bar: 1, row: 0, in: handle)
                let hit = try EditMeasureHitCodec.decode(
                    nativeEditingMeasureHitTest(scoreHandle: handle, xMm: point.x, yMm: point.y),
                )
                #expect(hit.firstMeasureIndex == 1)
                #expect(hit.lastMeasureIndex == 3)
            }

            @Test func `empty paper, an unknown handle and a handle never laid out answer nothing`() {
                let handle = Self.laidOut(Self.options())
                defer { Self.release(handle) }
                #expect(nativeEditingMeasureHitTest(scoreHandle: handle, xMm: 0, yMm: -500 * Self.ptToMM).isEmpty)
                #expect(nativeEditingMeasureHitTest(scoreHandle: 999_999, xMm: 0, yMm: 0).isEmpty)

                let bare = scoreTable.insert(Self.score())
                defer { scoreTable.release(bare) }
                #expect(nativeEditingMeasureHitTest(scoreHandle: bare, xMm: 0, yMm: 0).isEmpty)
            }

            @Test func `the measure-hit codec round-trips`() throws {
                let data = EditMeasureHitCodec.encode(
                    staff: StaffAddress(partIndex: 2, staffIndexInPart: 1), measures: 5 ... 9,
                )
                let wire = try EditMeasureHitCodec.decode(data)
                #expect(wire.partIndex == 2)
                #expect(wire.staffIndexInPart == 1)
                #expect(wire.firstMeasureIndex == 5)
                #expect(wire.lastMeasureIndex == 9)
            }
        }
    #endif
#endif
