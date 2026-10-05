#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import SheetMusicCore
    import SheetMusicLayout
    import Testing

    @Suite("Multi-measure rest anchors")
    struct MultiMeasureRestAnchorTests {
        private let _installApple = TestSupport.installApple

        @available(macOS 15.0, iOS 16.0, *)
        private func document() -> LayoutDocument {
            let rest = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
            let sound = Measure(voices: [Voice(elements: [.chord(Chord(
                duration: .whole, notes: [Note(pitch: 60, tpc: 14)],
            ))])])
            let score = Score(
                division: 480,
                parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(
                    measures: [sound, rest, rest, rest, rest, sound],
                )])],
                systemMeasures: IdentifiedArray(Array(repeating: SystemMeasure(), count: 6)),
            )
            return LayoutEngine.layout(
                score: score, options: .init(multiMeasureRest: .collapse(minimumMeasures: 2)), availableWidth: 1200,
            )
        }

        @Test func resolvesEachSlot() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = document()
            let system = try #require(doc.systems.first { $0.measures.contains { $0.multiMeasureRest == 4 } })
            let bar = try #require(system.measures.first { $0.multiMeasureRest == 4 })
            for slot in 0 ..< 4 {
                let point = CGPoint(
                    x: system.origin.x + bar.origin.x + (CGFloat(slot) + 0.25) * bar.width / 4,
                    y: system.origin.y + system.staffOrigins[0].y - system.sp,
                )
                let anchor = try #require(doc.resolveAnchor(at: point))
                #expect(anchor.measureIndex == 1 + slot)
                #expect(anchor.tickInMeasure == 0)
                #expect(abs(anchor.dxSp - bar.width / 16 / system.sp) < 0.001)
                #expect(abs(anchor.verticalOffsetSp + 1) < 0.001)
            }
        }

        @Test func referencesInteriorSlots() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = document()
            let system = try #require(doc.systems.first { $0.measures.contains { $0.multiMeasureRest == 4 } })
            let bar = try #require(system.measures.first { $0.multiMeasureRest == 4 })
            for slot in 0 ..< 4 {
                let reference = try #require(doc.anchorReferencePoint(
                    measureIndex: 1 + slot, tickInMeasure: 0, partIndex: 0, staffIndexInPart: 0,
                ))
                #expect(abs(reference.point.x - (system.origin.x + bar.origin.x + CGFloat(slot) * bar.width / 4))
                    < 0.001)
                #expect(reference.point.y == system.origin.y + system.staffOrigins[0].y)
            }
        }

        @Test func collapsedRoundTrip() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let doc = document()
            let system = try #require(doc.systems.first { $0.measures.contains { $0.multiMeasureRest == 4 } })
            let bar = try #require(system.measures.first { $0.multiMeasureRest == 4 })
            for fraction in [0.01, 0.25, 0.51, 0.99] {
                let point = CGPoint(
                    x: system.origin.x + bar.origin.x + fraction * bar.width,
                    y: system.origin.y + system.staffOrigins[0].y + 3 * system.sp,
                )
                let anchor = try #require(doc.resolveAnchor(at: point))
                let reference = try #require(doc.anchorReferencePoint(
                    measureIndex: anchor.measureIndex, tickInMeasure: anchor.tickInMeasure,
                    partIndex: anchor.partIndex, staffIndexInPart: anchor.staffIndexInPart,
                ))
                #expect(abs(reference.point.x + anchor.dxSp * reference.sp - point.x) < 0.001)
                #expect(abs(reference.point.y + anchor.verticalOffsetSp * reference.sp - point.y) < 0.001)
            }
        }
    }
#endif
