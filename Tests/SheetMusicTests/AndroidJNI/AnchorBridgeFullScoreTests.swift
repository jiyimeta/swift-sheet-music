#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    #if os(macOS)
        import CoreGraphics
        import Foundation
        @testable import SheetMusicAndroidJNI
        @testable import SheetMusicBridgeCore
        import SheetMusicCore
        @testable import SheetMusicLayout
        import Testing

        /// The full-score anchor verbs. Ink is stored in FULL-SCORE addressing (every staff the file declares), but a
        /// layout with staves hidden numbers its staves after the filter. `nativeResolveAnchor` /
        /// `nativeAnchorReferencePoint` answer in the layout's numbering, so with a staff hidden a captured stroke is
        /// stamped with the wrong staff and a stored stroke is drawn on the wrong one. These verbs translate on both
        /// sides through the hidden set the cached layout was computed from.
        @Suite("Anchor bridge, full-score addressing")
        struct AnchorBridgeFullScoreTests {
            private let _installApple = TestSupport.installApple
            private static let ptToMM = 25.4 / 72.0

            /// One part, two staves, two bars of a whole C4 on each.
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

            /// Two one-staff parts, the same bars.
            private static func twoParts() -> Score {
                let bar = Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
                ])])
                let staff = Staff(measures: [bar, bar])
                return Score(division: 480, parts: [
                    Part(id: "1", instrument: Instrument(id: "x"), staves: [staff]),
                    Part(id: "2", instrument: Instrument(id: "y"), staves: [staff]),
                ])
            }

            private static func options(hiding hidden: [HiddenStaffWire]) -> Data {
                var wire = LayoutOptionsWire.verticalDefault
                wire.hiddenStaves = hidden
                return wire.encodeToData()
            }

            private static func laidOut(_ score: Score, hiding hidden: [HiddenStaffWire] = []) -> Int64 {
                let handle = scoreTable.insert(score)
                _ = nativeComputeLayout(
                    scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: options(hiding: hidden),
                )
                return handle
            }

            private static func release(_ handle: Int64) {
                scoreTable.release(handle)
                LayoutDocumentCache.release(handle)
            }

            /// Bar 2's reference point (staff top line, tick 0) on `staff`, in DOCUMENT mm. `staff` is in the cached
            /// layout's own (filtered) numbering.
            private static func pointMm(
                onFiltered staff: StaffAddress, in handle: Int64,
            ) throws -> (x: Double, y: Double) {
                let document = try #require(LayoutDocumentCache.value(for: handle))
                let ref = try #require(document.anchorReferencePoint(
                    measureIndex: 1, tickInMeasure: 0,
                    partIndex: staff.partIndex, staffIndexInPart: staff.staffIndexInPart,
                ))
                return (Double(ref.point.x) * ptToMM, Double(ref.point.y) * ptToMM)
            }

            private static func identities(_ staves: [StaffAddress]) -> Data {
                staves.map {
                    AnchorIdentityWire(
                        measureIndex: 1, tickInMeasure: 0,
                        partIndex: Int32($0.partIndex), staffIndexInPart: Int32($0.staffIndexInPart),
                    )
                }.encodeToData()
            }

            @Test func `with nothing hidden the full-score verbs answer what the display verbs answer`() throws {
                let handle = Self.laidOut(Self.twoStaffPart())
                defer { Self.release(handle) }
                let point = try Self.pointMm(onFiltered: StaffAddress(partIndex: 0, staffIndexInPart: 1), in: handle)
                #expect(
                    nativeResolveFullScoreAnchor(scoreHandle: handle, tapXmm: point.x, tapYmm: point.y)
                        == nativeResolveAnchor(scoreHandle: handle, tapXmm: point.x, tapYmm: point.y),
                )
                let ids = Self.identities([
                    StaffAddress(partIndex: 0, staffIndexInPart: 0), StaffAddress(partIndex: 0, staffIndexInPart: 1),
                ])
                let fullScoreRefs = nativeFullScoreAnchorReferencePoint(scoreHandle: handle, anchorsBytes: ids)
                #expect(!fullScoreRefs.isEmpty)
                #expect(fullScoreRefs == nativeAnchorReferencePoint(scoreHandle: handle, anchorsBytes: ids))
            }

            /// Staff 1 is the only staff the filtered layout has, numbered 0 there. A stroke drawn on it has to be
            /// stored as staff 1. The display verb's answer, staff 0, names the hidden staff.
            @Test func `a point on the staff below a hidden one resolves to its full-score staff`() throws {
                let handle = Self.laidOut(
                    Self.twoStaffPart(), hiding: [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)],
                )
                defer { Self.release(handle) }
                let point = try Self.pointMm(onFiltered: StaffAddress(partIndex: 0, staffIndexInPart: 0), in: handle)

                let full = try ResolvedAnchorWire(
                    decoding: nativeResolveFullScoreAnchor(scoreHandle: handle, tapXmm: point.x, tapYmm: point.y),
                )
                #expect(full.measureIndex == 1)
                #expect(full.partIndex == 0)
                #expect(full.staffIndexInPart == 1)

                let display = try ResolvedAnchorWire(
                    decoding: nativeResolveAnchor(scoreHandle: handle, tapXmm: point.x, tapYmm: point.y),
                )
                #expect(display.staffIndexInPart == 0) // the drift this row closes, pinned
            }

            /// A stored stroke on full-score staff 1 is drawn on that staff. The display verb looks up filtered staff
            /// 1, which does not exist, and drops it.
            @Test func `a full-score identity below a hidden staff finds its staff`() throws {
                let handle = Self.laidOut(
                    Self.twoStaffPart(), hiding: [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)],
                )
                defer { Self.release(handle) }
                let expected = try Self.pointMm(
                    onFiltered: StaffAddress(partIndex: 0, staffIndexInPart: 0), in: handle,
                )
                let ids = Self.identities([StaffAddress(partIndex: 0, staffIndexInPart: 1)])

                let full = try [AnchorRefPointWire](
                    decoding: nativeFullScoreAnchorReferencePoint(scoreHandle: handle, anchorsBytes: ids),
                )
                #expect(full.count == 1)
                #expect(full[0].spMm > 0)
                #expect(abs(full[0].xMm - expected.x) < 0.001)
                #expect(abs(full[0].yMm - expected.y) < 0.001)

                let display = try [AnchorRefPointWire](
                    decoding: nativeAnchorReferencePoint(scoreHandle: handle, anchorsBytes: ids),
                )
                #expect(display[0].spMm == 0)
            }

            /// Ink on a hidden staff is not drawn, and it keeps its slot so the caller drops only that stroke.
            @Test func `an identity on a hidden staff answers the sentinel in its own slot`() throws {
                let handle = Self.laidOut(
                    Self.twoStaffPart(), hiding: [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)],
                )
                defer { Self.release(handle) }
                let ids = Self.identities([
                    StaffAddress(partIndex: 0, staffIndexInPart: 0), StaffAddress(partIndex: 0, staffIndexInPart: 1),
                ])
                let out = try [AnchorRefPointWire](
                    decoding: nativeFullScoreAnchorReferencePoint(scoreHandle: handle, anchorsBytes: ids),
                )
                #expect(out.count == 2)
                #expect(out[0].spMm == 0)
                #expect(out[1].spMm > 0)
            }

            /// Hiding every staff of part 0 drops the part, so part 1 is part 0 in the filtered layout.
            @Test func `hiding a whole earlier part renumbers parts both ways`() throws {
                let handle = Self.laidOut(Self.twoParts(), hiding: [HiddenStaffWire(partIndex: 0, staffIndexInPart: 0)])
                defer { Self.release(handle) }
                let point = try Self.pointMm(onFiltered: StaffAddress(partIndex: 0, staffIndexInPart: 0), in: handle)
                let full = try ResolvedAnchorWire(
                    decoding: nativeResolveFullScoreAnchor(scoreHandle: handle, tapXmm: point.x, tapYmm: point.y),
                )
                #expect(full.partIndex == 1)
                #expect(full.staffIndexInPart == 0)

                let out = try [AnchorRefPointWire](decoding: nativeFullScoreAnchorReferencePoint(
                    scoreHandle: handle,
                    anchorsBytes: Self.identities([StaffAddress(partIndex: 1, staffIndexInPart: 0)]),
                ))
                #expect(out[0].spMm > 0)
            }

            /// A staff the score does not have answers the sentinel, with or without a hidden set.
            @Test func `an identity naming no staff of the score answers the sentinel`() throws {
                let handle = Self.laidOut(Self.twoParts())
                defer { Self.release(handle) }
                let out = try [AnchorRefPointWire](decoding: nativeFullScoreAnchorReferencePoint(
                    scoreHandle: handle,
                    anchorsBytes: Self.identities([StaffAddress(partIndex: 5, staffIndexInPart: 0)]),
                ))
                #expect(out[0].spMm == 0)
            }

            @Test func `no answer without a score, a cached layout or decodable bytes`() {
                let ids = Self.identities([StaffAddress(partIndex: 0, staffIndexInPart: 0)])
                #expect(nativeResolveFullScoreAnchor(scoreHandle: 999_999, tapXmm: 0, tapYmm: 0).isEmpty)
                #expect(nativeFullScoreAnchorReferencePoint(scoreHandle: 999_999, anchorsBytes: ids).isEmpty)

                let handle = scoreTable.insert(Self.twoParts())
                defer { Self.release(handle) }
                #expect(nativeResolveFullScoreAnchor(scoreHandle: handle, tapXmm: 0, tapYmm: 0).isEmpty)
                #expect(nativeFullScoreAnchorReferencePoint(scoreHandle: handle, anchorsBytes: ids).isEmpty)

                _ = nativeComputeLayout(
                    scoreHandle: handle, pageWidthMM: 210, pageHeightMM: 297, optionsBlob: Self.options(hiding: []),
                )
                #expect(nativeFullScoreAnchorReferencePoint(scoreHandle: handle, anchorsBytes: Data([0xFF])).isEmpty)

                // An edit drops the cached layout before it can disagree with the score it renumbers against.
                LayoutDocumentCache.invalidate(handle)
                #expect(nativeFullScoreAnchorReferencePoint(scoreHandle: handle, anchorsBytes: ids).isEmpty)
            }
        }
    #endif
#endif
