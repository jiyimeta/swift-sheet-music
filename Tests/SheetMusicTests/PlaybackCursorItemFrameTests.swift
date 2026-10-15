#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    import SheetMusicMSCX
    import Testing

    /// `cursorFrame(for: .item(…))` looks for the item in the measure its ID names before scanning the score. On
    /// real scores, in both layouts, every engraved notehead and rest still gets a frame on its own column, in the
    /// system it is drawn in.
    @Suite("cursorFrame finds every item in its own measure")
    struct PlaybackCursorItemFrameTests {
        private let _installFontMetrics = TestSupport.installFontMetrics

        @Test(
            "every notehead and rest frames on its own column",
            arguments: ["testSingleNoteDynamics", "lyrics_verses_melisma", "testMeasureRepeats", "midi01"],
        )
        func everyItemFrames(fixture: String) throws {
            guard #available(macOS 15.0, *) else { return }
            let url = URL(fileURLWithPath: "Tests/SheetMusicTests/Resources").appendingPathComponent("\(fixture).mscx")
            let score = try MSCXParser.parse(Data(contentsOf: url))
            let horizontal = ScoreViewOptions(wrapToViewWidth: false)
            let documents = [
                LayoutEngine.layout(
                    score: score, options: horizontal,
                    availableWidth: LayoutEngine.naturalContentWidth(score: score, options: horizontal),
                ),
                LayoutEngine.layout(
                    score: score, options: ScoreViewOptions(wrapToViewWidth: true), availableWidth: 500,
                ),
            ]
            for document in documents {
                var checked = 0
                for system in document.systems {
                    for measure in system.measures {
                        for element in measure.elements {
                            let item: (id: ScoreItemID, x: CGFloat)
                            switch element {
                            case let .chord(notes, _, _, _, _, _, _, _, _, _, _):
                                guard let first = notes.first else { continue }
                                item = (.note(first.noteID), first.origin.x)
                            case let .rest(duration, origin, _, restID, _) where duration != .measure:
                                item = (.rest(restID), origin.x)
                            default:
                                continue
                            }
                            let frame = try #require(document.cursorFrame(for: .item(item.id), in: score))
                            #expect(abs(frame.midX - (system.origin.x + measure.origin.x + item.x)) < 0.001)
                            #expect(frame.minY >= system.origin.y)
                            #expect(frame.maxY <= system.origin.y + system.size.height + 1)
                            checked += 1
                        }
                    }
                }
                #expect(checked > 0, "sanity: \(fixture) has items")
            }
        }
    }
#endif
