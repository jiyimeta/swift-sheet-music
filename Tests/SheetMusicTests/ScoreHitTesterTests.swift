#if os(macOS)
    import CoreGraphics
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    @Suite("ScoreHitTester")
    struct ScoreHitTesterTests {
        private let _installApple = TestSupport.installApple

        private func sample() -> Score {
            let chord = { (p: Int) -> VoiceElement in
                .chord(Chord(
                    duration: .quarter,
                    notes: [Note(pitch: p, tpc: 14)],
                ))
            }
            let measure = Measure(voices: [
                Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    chord(60), .rest(duration: .quarter),
                    chord(64), chord(65),
                ]),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "piano", longName: "Piano"),
                    staves: [Staff(
                        staffType: "stdNormal",
                        group: "pitched",
                        defaultClefType: "G",
                        measures: [measure],
                    )],
                )],
            )
        }

        @Test("Tap on a notehead returns the matching ScoreItemID")
        func hitsNotehead() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = sample()
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 600,
            )
            let tester = ScoreHitTester(document: doc)

            let system = try #require(doc.systems.first)
            var target: (x: CGFloat, y: CGFloat, id: NoteID)?
            for measure in system.measures {
                for el in measure.elements {
                    guard case let .chord(notes, _, _, _, _, _, _, _, _, _) = el,
                          let n = notes.first
                    else { continue }
                    let ax = system.origin.x + measure.origin.x + n.origin.x
                    let ay = system.origin.y + measure.origin.y + n.origin.y
                    target = (ax, ay, n.noteID)
                    break
                }
                if target != nil { break }
            }
            let hit = try #require(target)
            let id = tester.itemID(at: CGPoint(x: hit.x, y: hit.y))
            #expect(id == .note(hit.id))
        }

        @Test("Tap on a rest returns its RestID")
        func hitsRest() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = sample()
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 600,
            )
            let tester = ScoreHitTester(document: doc)

            let system = try #require(doc.systems.first)
            var target: (x: CGFloat, y: CGFloat, id: RestID)?
            for measure in system.measures {
                for el in measure.elements {
                    guard case let .rest(_, origin, _, rid, _) = el
                    else { continue }
                    let ax = system.origin.x + measure.origin.x + origin.x
                    let ay = system.origin.y + measure.origin.y + origin.y
                    target = (ax, ay, rid)
                    break
                }
                if target != nil { break }
            }
            let hit = try #require(target)
            let id = tester.itemID(at: CGPoint(x: hit.x, y: hit.y))
            #expect(id == .rest(hit.id))
        }

        @Test("Tap on empty space returns nil")
        func missesEmptySpace() {
            guard #available(macOS 15.0, *) else { return }
            let score = sample()
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 600,
            )
            let tester = ScoreHitTester(document: doc)
            // Far above the system — definitely no notes or rests.
            let id = tester.itemID(at: CGPoint(x: 0, y: -500))
            #expect(id == nil)
        }

        @Test("itemIDs(in:) returns events whose bbox intersects the rect")
        func marqueeBasic() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = sample()
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 600,
            )
            let tester = ScoreHitTester(document: doc)

            // Rect that covers the whole first system.
            let system = try #require(doc.systems.first)
            let allRect = CGRect(
                x: system.origin.x,
                y: system.origin.y,
                width: system.size.width,
                height: system.size.height,
            )
            let allIds = tester.itemIDs(in: allRect)
            // 3 chords + 1 rest from sample().
            #expect(allIds.count == 4)
        }

        @Test("itemIDs(in:) misses events outside the rect")
        func marqueeEmpty() {
            guard #available(macOS 15.0, *) else { return }
            let score = sample()
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 600,
            )
            let tester = ScoreHitTester(document: doc)
            // Rect far below the system.
            let rect = CGRect(x: 0, y: 100_000, width: 10, height: 10)
            #expect(tester.itemIDs(in: rect).isEmpty)
        }

        @Test("itemIDs(in:) preserves visit order (sorted by centerX)")
        func marqueeOrder() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = sample()
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 600,
            )
            let tester = ScoreHitTester(document: doc)

            let system = try #require(doc.systems.first)
            let allRect = CGRect(
                x: system.origin.x, y: system.origin.y,
                width: system.size.width, height: system.size.height,
            )
            let ids = tester.itemIDs(in: allRect)
            // Resolve each id back to its centerX via system.eventColumns
            // and verify they're in ascending order.
            let xs: [CGFloat] = ids.compactMap { id in
                system.eventColumns.first(where: { $0.id == id })
                    .map { $0.centerX + system.origin.x }
            }
            #expect(xs == xs.sorted())
        }

        @Test("itemIDs(in:) catches events whose bbox grazes the rect")
        func marqueeGrazingBbox() throws {
            guard #available(macOS 15.0, *) else { return }
            let score = sample()
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(),
                availableWidth: 600,
            )
            let tester = ScoreHitTester(document: doc)
            let system = try #require(doc.systems.first)
            let firstColumn = try #require(system.eventColumns.first)

            // Rect sits to the LEFT of the column's centerX (so the X
            // binary-search would prune it without `maxBBoxHalfWidth`
            // tolerance) but still overlaps the column's bbox by 1 pt.
            // Documents the core algorithmic guarantee: the tolerance
            // window is wide enough that no bbox-intersecting event
            // gets pruned.
            let bbox = firstColumn.bbox
            let docMinX = system.origin.x + bbox.minX
            let rect = CGRect(
                x: docMinX - 5,
                y: system.origin.y + bbox.minY,
                width: 6, // overlaps bbox by 1 pt on the right
                height: bbox.height,
            )
            let ids = tester.itemIDs(in: rect)
            #expect(ids.contains(firstColumn.id))
        }
    }
#endif
