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

        /// `nativeEditingHitTarget` — the raw `ScoreHitTester.hitTest(at:)` answer a host needs beside
        /// `nativeEditingHitTest`, whose policy drops clefs, engraved elements and text on purpose (what a click on
        /// them means is the host's call). Answered as the item the target names (`selectableItem`), re-addressed past
        /// the cached layout's hidden staves like its sibling.
        @Suite("Edit hit target bridge")
        struct EditHitTargetBridgeTests {
            private let _installApple = TestSupport.installApple
            private static let ptToMM = 25.4 / 72.0
            private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)
            private static let staff1 = StaffAddress(partIndex: 0, staffIndexInPart: 1)

            /// One part, two staves, two bars of a whole C4.
            private static func twoStaffPart() -> Score {
                let bar = Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
                ])])
                let staff = Staff(measures: [bar, bar])
                return Score(
                    division: 480,
                    parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff, staff])],
                )
            }

            private static func laidOut(_ score: Score, hiding hidden: [HiddenStaffWire] = []) -> Int64 {
                let handle = scoreTable.insert(score)
                var wire = LayoutOptionsWire.verticalDefault
                wire.hiddenStaves = hidden
                _ = nativeComputeLayout(
                    scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: wire.encodeToData(),
                )
                return handle
            }

            private static func release(_ handle: Int64) {
                scoreTable.release(handle)
                LayoutDocumentCache.release(handle)
            }

            /// The first system's first leading clef, in document points.
            private static func leadingClef(in handle: Int64) throws -> CGPoint {
                let document = try #require(LayoutDocumentCache.value(for: handle))
                let system = try #require(document.systems.first)
                let measure = try #require(system.measures.first)
                for element in measure.elements {
                    if case let .clef(_, origin, _, _) = element {
                        return CGPoint(
                            x: system.origin.x + measure.origin.x + origin.x,
                            y: system.origin.y + measure.origin.y + origin.y,
                        )
                    }
                }
                Issue.record("no leading clef in the first measure")
                return .zero
            }

            private static func target(_ handle: Int64, at point: CGPoint) throws -> ScoreItemID? {
                let bytes = nativeEditingHitTarget(
                    scoreHandle: handle, xMm: Double(point.x) * ptToMM, yMm: Double(point.y) * ptToMM,
                )
                return bytes.isEmpty ? nil : try ScoreItemIDCodec.decode(bytes)
            }

            /// The case `nativeEditingHitTest` cannot answer: its policy drops a clef target.
            @Test func `a tap on a leading clef names the clef`() throws {
                let handle = Self.laidOut(Self.twoStaffPart())
                defer { Self.release(handle) }
                #expect(try Self.target(handle, at: Self.leadingClef(in: handle)) == .clef(.staffDefault(Self.staff0)))
            }

            /// Staff 0 hidden: the only drawn clef is the filtered layout's staff 0, which is the score's staff 1.
            @Test func `the target is re-addressed past the cache's hidden staves`() throws {
                let handle = Self.laidOut(
                    Self.twoStaffPart(), hiding: [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)],
                )
                defer { Self.release(handle) }
                #expect(try Self.target(handle, at: Self.leadingClef(in: handle)) == .clef(.staffDefault(Self.staff1)))
            }

            @Test func `no answer far from any staff, for an unknown handle, or before a layout`() throws {
                let handle = Self.laidOut(Self.twoStaffPart())
                defer { Self.release(handle) }
                #expect(try Self.target(handle, at: CGPoint(x: 0, y: -500)) == nil)

                #expect(nativeEditingHitTarget(scoreHandle: 987_654, xMm: 0, yMm: 0).isEmpty)

                let unlaid = scoreTable.insert(Self.twoStaffPart())
                defer { scoreTable.release(unlaid) }
                #expect(nativeEditingHitTarget(scoreHandle: unlaid, xMm: 0, yMm: 0).isEmpty)
            }
        }
    #endif
#endif
