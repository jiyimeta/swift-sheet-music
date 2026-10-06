#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    #if os(macOS)
        import Foundation
        @testable import SheetMusicAndroidJNI
        @testable import SheetMusicBridgeCore
        @testable import SheetMusicCore
        import Testing

        /// `nativeMeasureColumnIDs` — the column identities a host maps a stored anchor through, so ink follows its bar
        /// when bars are inserted or deleted before it. The table has to describe the same revision as the cached
        /// layout the anchors are drawn against, so it is read from the cache entry's score, not the handle's.
        @Suite("Measure column IDs bridge")
        struct MeasureColumnIDsBridgeTests {
            private let _installApple = TestSupport.installApple

            private static let first = EID(first: 42, second: 1)
            private static let second = EID(first: 42, second: 2)
            private static let third = EID(first: 42, second: 3)

            /// One part, two staves, `ids.count` bars of a whole C4, the columns carrying `ids` (`.invalid` for an
            /// unassigned one).
            private static func score(columns ids: [EID]) -> Score {
                let bar = Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
                ])])
                let staff = Staff(measures: Array(repeating: bar, count: ids.count))
                var score = Score(
                    division: 480,
                    parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff, staff])],
                )
                score.systemMeasures = IdentifiedArray(ids.map { ($0, SystemMeasure(elements: [])) })
                return score
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

            private static func ids(_ handle: Int64) throws -> [String] {
                try [MeasureColumnIDWire](decoding: nativeMeasureColumnIDs(scoreHandle: handle)).map(\.id)
            }

            @Test func `the table is the cached score's column identities, in measure order`() throws {
                let handle = Self.laidOut(Self.score(columns: [Self.first, Self.second, Self.third]))
                defer { Self.release(handle) }
                #expect(try Self.ids(handle) == [Self.first, Self.second, Self.third].map(\.stringValue))
            }

            @Test func `an unassigned column is the empty string, in its own slot`() throws {
                let handle = Self.laidOut(Self.score(columns: [Self.first, .invalid, Self.third]))
                defer { Self.release(handle) }
                #expect(try Self.ids(handle) == [Self.first.stringValue, "", Self.third.stringValue])
            }

            /// Hiding a staff drops rows, never columns: the table is the same, so a stored identity still resolves.
            @Test func `hiding a staff keeps every column`() throws {
                let handle = Self.laidOut(
                    Self.score(columns: [Self.first, Self.second]),
                    hiding: [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)],
                )
                defer { Self.release(handle) }
                #expect(try Self.ids(handle) == [Self.first, Self.second].map(\.stringValue))
            }

            /// An edit replaces the handle's score before the next layout files its document. Until then the anchors
            /// are still drawn against the old layout, so the table must still describe the old revision.
            @Test func `the table speaks the cached layout's revision, not a newer score's`() throws {
                let handle = Self.laidOut(Self.score(columns: [Self.first, Self.second]))
                defer { Self.release(handle) }
                #expect(scoreTable.replace(handle, with: Self.score(columns: [Self.third, Self.first, Self.second])))
                #expect(try Self.ids(handle) == [Self.first, Self.second].map(\.stringValue))
            }

            @Test func `no answer for an unknown handle, a score never laid out, or an invalidated layout`() {
                #expect(nativeMeasureColumnIDs(scoreHandle: 987_654).isEmpty)

                let unlaid = scoreTable.insert(Self.score(columns: [Self.first]))
                defer { Self.release(unlaid) }
                #expect(nativeMeasureColumnIDs(scoreHandle: unlaid).isEmpty)

                let edited = Self.laidOut(Self.score(columns: [Self.first]))
                defer { Self.release(edited) }
                LayoutDocumentCache.invalidate(edited)
                #expect(nativeMeasureColumnIDs(scoreHandle: edited).isEmpty)
            }
        }
    #endif
#endif
