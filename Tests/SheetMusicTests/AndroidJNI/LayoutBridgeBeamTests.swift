#if SHEET_MUSIC_HAS_ANDROID_JNI_TEST_SUPPORT
    import CoreGraphics
    @testable import SheetMusicBridgeCore
    import SheetMusicCore
    import SheetMusicLayout
    import Testing

    /// A beam is Apple's `drawBeam` quadrilateral, filled: its inner edge on the stem-tip line shifted by the level
    /// offset, its outer edge one thickness further, both along Y. The stroked center line it replaced tilts its
    /// end caps with the slope, which is where a sloped beam used to part from Apple's.
    ///
    /// The expected corners are Apple's arithmetic spelled out here (thickness 0.5 sp, gap 0.3 sp), not read back
    /// through `BeamGeometry`, so a drift in either side shows.
    @Suite("LayoutBridge beams")
    struct LayoutBridgeBeamTests {
        /// Points → document mm, the same factor `LayoutBridge` applies.
        private static let mm = 25.4 / 72.0

        @Test(arguments: [StemDirection.up, .down], [1, 2])
        func aSlopedBeamIsAppleQuadrilateral(direction: StemDirection, level: Int) throws {
            let from = CGPoint(x: 10, y: 30)
            let to = CGPoint(x: 70, y: 22)
            let doc = ElementHitFixtures.document([
                .beam(fromOrigin: from, toOrigin: to, direction: direction, level: level),
            ])
            let commands = LayoutBridge.buildCommands(layout: doc)
            try #require(commands.count == 5)
            #expect(commands[4] == .fillPath)

            let sp = Double(doc.metrics.sp)
            let thickness = sp * 0.5
            let gap = sp * 0.3
            let stackSign: Double = direction == .up ? 1 : -1
            let dy = Double(level - 1) * (thickness + gap) * stackSign
            let inner = dy
            let outer = dy + thickness * stackSign
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            let ox = Double(system.origin.x + measure.origin.x)
            let oy = Double(system.origin.y + measure.origin.y)
            let (fx, fy, tx, ty) = (Double(from.x), Double(from.y), Double(to.x), Double(to.y))
            let expected = [(fx, fy + inner), (tx, ty + inner), (tx, ty + outer), (fx, fy + outer)]
                .map { (x: (ox + $0.0) * Self.mm, y: (oy + $0.1) * Self.mm) }

            for (index, corner) in expected.enumerated() {
                let point: (x: Double, y: Double)
                switch commands[index] {
                case let .moveTo(x, y) where index == 0: point = (x, y)
                case let .lineTo(x, y) where index > 0: point = (x, y)
                default:
                    Issue.record("corner \(index) is \(commands[index]), not a path point")
                    continue
                }
                #expect(abs(point.x - corner.x) < 1e-9, "corner \(index) x")
                #expect(abs(point.y - corner.y) < 1e-9, "corner \(index) y")
            }
        }

        /// The ends stay vertical whatever the slope: each end's two corners share an x, and the bar is one
        /// thickness tall there — what a stroked center line could not give a sloped beam.
        @Test(arguments: [StemDirection.up, .down])
        func aSlopedBeamKeepsVerticalEnds(direction: StemDirection) throws {
            let doc = ElementHitFixtures.document([.beam(
                fromOrigin: CGPoint(x: 0, y: 40), toOrigin: CGPoint(x: 60, y: 10), direction: direction, level: 1,
            )])
            let commands = LayoutBridge.buildCommands(layout: doc)
            try #require(commands.count == 5)
            guard case let .moveTo(x0, y0) = commands[0], case let .lineTo(x1, y1) = commands[1],
                  case let .lineTo(x2, y2) = commands[2], case let .lineTo(x3, y3) = commands[3]
            else {
                Issue.record("expected moveTo and three lineTo, got \(commands)")
                return
            }
            let thicknessMM = Double(doc.metrics.sp) * 0.5 * Self.mm
            #expect(abs(x0 - x3) < 1e-9)
            #expect(abs(x1 - x2) < 1e-9)
            #expect(abs(abs(y3 - y0) - thicknessMM) < 1e-9)
            #expect(abs(abs(y2 - y1) - thicknessMM) < 1e-9)
        }

        /// An authored beam color brackets the fill and restores ink after it, as it bracketed the stroke.
        @Test
        func aColoredBeamBracketsItsFill() throws {
            let doc = ElementHitFixtures.document([
                .beam(
                    fromOrigin: CGPoint(x: 10, y: 30), toOrigin: CGPoint(x: 70, y: 22), direction: .up, level: 1,
                    color: ScoreColor(red: 200, green: 10, blue: 20),
                ),
            ])
            let commands = LayoutBridge.buildCommands(layout: doc)
            try #require(commands.count == 7)
            #expect(commands[0] == .setColor(argb: 0xFFC8_0A14))
            #expect(commands[5] == .fillPath)
            #expect(commands[6] == .setColor(argb: LayoutBridge.blackARGB))
        }
    }
#endif
