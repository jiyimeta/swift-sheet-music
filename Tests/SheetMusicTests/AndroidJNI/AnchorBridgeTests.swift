#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    #if os(macOS)
        import CoreGraphics
        import Foundation
        @testable import SheetMusicAndroidJNI
        @testable import SheetMusicBridgeCore
        import SheetMusicCore
        @testable import SheetMusicLayout
        import Testing

        @Suite("Anchor bridge")
        struct AnchorBridgeTests {
            private let _installApple = TestSupport.installApple

            // MARK: - Codec round-trips

            @Test("ResolvedAnchorWire round-trips through its wire codec")
            func resolvedAnchorRoundTrip() throws {
                let wire = ResolvedAnchorWire(
                    measureIndex: 3, tickInMeasure: 240, partIndex: 1, staffIndexInPart: 0,
                    dxSp: 1.5, verticalOffsetSp: -2.0,
                )
                #expect(try ResolvedAnchorWire(decoding: wire.encodeToData()) == wire)
            }

            @Test("Anchor identity + ref-point arrays round-trip (wirelet i32-count arrays)")
            func batchedArraysRoundTrip() throws {
                let ids = [
                    AnchorIdentityWire(measureIndex: 0, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
                    AnchorIdentityWire(measureIndex: 2, tickInMeasure: 120, partIndex: 1, staffIndexInPart: 1),
                ]
                #expect(try [AnchorIdentityWire](decoding: ids.encodeToData()) == ids)

                let pts = [
                    AnchorRefPointWire(xMm: 10, yMm: 20, spMm: 1.76),
                    AnchorRefPointWire(xMm: 0, yMm: 0, spMm: 0), // unresolved sentinel
                ]
                #expect(try [AnchorRefPointWire](decoding: pts.encodeToData()) == pts)
            }

            // MARK: - Bridge over the layout cache

            @available(macOS 15.0, *)
            private func cachedTwoMeasure(handle: Int64) -> Score {
                let note = Note(pitch: 60, tpc: 14)
                let chord = Chord(duration: .whole, notes: [note])
                let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
                let staff = Staff(measures: [measure, measure])
                let score = Score(
                    division: 480,
                    parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [staff])],
                )
                let doc = LayoutEngine.layout(score: score, options: .init(), availableWidth: 800)
                LayoutDocumentCache.store(handle: handle, document: doc, filteredScore: score, hiddenStaves: [])
                return score
            }

            @Test("nativeResolveAnchor resolves a document-mm point to a ResolvedAnchor; empty Data on miss")
            func resolveAnchorBridge() throws {
                guard #available(macOS 15.0, *) else { return }
                let handle: Int64 = 4242
                _ = cachedTwoMeasure(handle: handle)
                defer { LayoutDocumentCache.release(handle) }

                let doc = try #require(LayoutDocumentCache.value(for: handle))
                let ref = try #require(doc.anchorReferencePoint(
                    measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                ))
                let ptToMM = 25.4 / 72.0
                let data = nativeResolveAnchor(
                    scoreHandle: handle,
                    tapXmm: Double(ref.point.x) * ptToMM,
                    tapYmm: Double(ref.point.y) * ptToMM,
                )
                let wire = try ResolvedAnchorWire(decoding: data)
                #expect(wire.measureIndex == 1)
                #expect(wire.partIndex == 0)
                #expect(wire.staffIndexInPart == 0)
                #expect(abs(wire.dxSp) < 0.01)
                #expect(abs(wire.verticalOffsetSp) < 0.01)

                // Unknown handle -> empty Data.
                #expect(nativeResolveAnchor(scoreHandle: 9999, tapXmm: 0, tapYmm: 0).isEmpty)
            }

            @Test("nativeAnchorReferencePoint batches ref points in mm, sentinel on miss, positionally aligned")
            func anchorReferencePointBridge() throws {
                guard #available(macOS 15.0, *) else { return }
                let handle: Int64 = 4343
                _ = cachedTwoMeasure(handle: handle)
                defer { LayoutDocumentCache.release(handle) }

                let ids = [
                    AnchorIdentityWire(measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0),
                    AnchorIdentityWire(measureIndex: 99, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0), // miss
                ]
                let out = try [AnchorRefPointWire](
                    decoding: nativeAnchorReferencePoint(scoreHandle: handle, anchorsBytes: ids.encodeToData()),
                )
                #expect(out.count == 2)
                #expect(out[0].spMm > 0) // resolved
                #expect(out[1].spMm == 0) // sentinel: unresolved, alignment preserved

                let doc = try #require(LayoutDocumentCache.value(for: handle))
                let ref = try #require(doc.anchorReferencePoint(
                    measureIndex: 1, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                ))
                let ptToMM = 25.4 / 72.0
                #expect(abs(out[0].xMm - Double(ref.point.x) * ptToMM) < 0.001)
                #expect(abs(out[0].yMm - Double(ref.point.y) * ptToMM) < 0.001)
                #expect(abs(out[0].spMm - Double(ref.sp) * ptToMM) < 0.001)

                // Unknown handle -> empty Data.
                #expect(nativeAnchorReferencePoint(scoreHandle: 9999, anchorsBytes: ids.encodeToData()).isEmpty)
            }
        }
    #endif
#endif
