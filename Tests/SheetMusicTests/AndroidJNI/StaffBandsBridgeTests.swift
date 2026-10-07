#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    #if os(macOS)
        import Foundation
        @testable import SheetMusicAndroidJNI
        @testable import SheetMusicBridgeCore
        @testable import SheetMusicCore
        @testable import SheetMusicLayout
        import Testing

        /// `nativeStaffBands` — the rectangles a host shades to highlight a staff. They come from
        /// `LayoutDocument.staffBands(verticalPaddingSp:)`, the one implementation of the band math, so Android shades
        /// exactly what an Apple host does; the verb converts to millimetres and re-addresses to the full score.
        @Suite("Staff bands bridge")
        struct StaffBandsBridgeTests {
            private let _installApple = TestSupport.installApple

            private static let ptToMm = 25.4 / 72.0

            /// One part, two staves, `bars` bars of a whole C4.
            private static func score(bars: Int = 3) -> Score {
                let bar = Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
                ])])
                let staff = Staff(measures: Array(repeating: bar, count: bars))
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

            private static func bands(_ handle: Int64, paddingSp: Double) throws -> [StaffBandWire] {
                try [StaffBandWire](decoding: nativeStaffBands(scoreHandle: handle, verticalPaddingSp: paddingSp))
            }

            @Test func `one band per staff per system, the document's bands in millimetres`() throws {
                let handle = Self.laidOut(Self.score())
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                let expected = document.staffBands(verticalPaddingSp: 1)
                let wires = try Self.bands(handle, paddingSp: 1)

                #expect(wires.count == document.systems.count * 2)
                #expect(wires.count == expected.count)
                for (wire, band) in zip(wires, expected) {
                    #expect(wire.partIndex == Int32(band.staff.partIndex))
                    #expect(wire.staffIndexInPart == Int32(band.staff.staffIndexInPart))
                    #expect(abs(wire.xMm - Double(band.rect.minX) * Self.ptToMm) < 1e-9)
                    #expect(abs(wire.yMm - Double(band.rect.minY) * Self.ptToMm) < 1e-9)
                    #expect(abs(wire.widthMm - Double(band.rect.width) * Self.ptToMm) < 1e-9)
                    #expect(abs(wire.heightMm - Double(band.rect.height) * Self.ptToMm) < 1e-9)
                }
                #expect(Set(wires.map(\.staffIndexInPart)) == [0, 1])
            }

            /// A five-line staff's band covers its four spaces exactly, and each staff space of padding moves its top
            /// up one space and adds two to its height.
            @Test func `a band spans the staff lines plus the padding above and below`() throws {
                let handle = Self.laidOut(Self.score())
                defer { Self.release(handle) }
                let document = try #require(LayoutDocumentCache.entry(for: handle)?.document)
                let spMm = Double(document.metrics.sp) * Self.ptToMm
                let tight = try #require(Self.bands(handle, paddingSp: 0).first)
                let padded = try #require(Self.bands(handle, paddingSp: 1).first)

                #expect(abs(tight.heightMm - 4 * spMm) < 1e-9)
                #expect(abs(padded.heightMm - tight.heightMm - 2 * spMm) < 1e-9)
                #expect(abs(tight.yMm - padded.yMm - spMm) < 1e-9)
                let system = try #require(document.systems.first)
                let staffTop = Double(system.origin.y + system.staffOrigins[0].y) * Self.ptToMm
                #expect(abs(tight.yMm - staffTop) < 1e-9)
            }

            /// The cached document of a score with its first staff hidden names the second staff (0, 0). The verb
            /// answers in the full score's addressing, so a host's highlight for (0, 1) still finds its band.
            @Test func `a hidden staff has no band and the shown one keeps its full-score address`() throws {
                let handle = Self.laidOut(Self.score(), hiding: [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)])
                defer { Self.release(handle) }
                let wires = try Self.bands(handle, paddingSp: 1)

                #expect(!wires.isEmpty)
                #expect(wires.allSatisfy { $0.partIndex == 0 && $0.staffIndexInPart == 1 })
            }

            @Test func `no answer for an unknown handle or a score never laid out`() {
                #expect(nativeStaffBands(scoreHandle: 987_654, verticalPaddingSp: 1).isEmpty)

                let unlaid = scoreTable.insert(Self.score())
                defer { Self.release(unlaid) }
                #expect(nativeStaffBands(scoreHandle: unlaid, verticalPaddingSp: 1).isEmpty)
            }
        }
    #endif
#endif
