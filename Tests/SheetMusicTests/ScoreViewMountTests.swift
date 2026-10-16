#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicLayoutApple
    import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    /// Which systems `ScoreView(document:visibleRect:)` mounts.
    @Suite("ScoreView mounted systems")
    struct ScoreViewMountTests {
        @available(macOS 15.0, *)
        private func document() throws -> LayoutDocument {
            _ = SheetMusicLayoutApple.install
            let url = URL(fileURLWithPath: "Tests/SheetMusicTests/Resources")
                .appendingPathComponent("testMeasureRepeats.mscx")
            let score = try MSCXParser.parse(Data(contentsOf: url))
            // Narrow enough that the fixture wraps onto several systems.
            return LayoutEngine.layout(
                score: score, options: ScoreViewOptions(wrapToViewWidth: true), availableWidth: 300,
            )
        }

        @Test("no visible rect mounts every system")
        func nilMountsEverySystem() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = try document()
            try #require(doc.systems.count >= 3)
            #expect(ScoreView.mountedSystemIndices(of: doc, in: nil) == Array(doc.systems.indices))
        }

        @Test("a rect over one system mounts that system and no other")
        func rectMountsOnlyWhatItMeets() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = try document()
            try #require(doc.systems.count >= 3)
            let middle = doc.systems[1]
            let rect = CGRect(
                x: 0, y: middle.origin.y + 2, width: doc.size.width, height: max(1, middle.size.height - 4),
            )
            #expect(ScoreView.mountedSystemIndices(of: doc, in: rect) == [1])
        }

        @Test("a rect over the whole document mounts every system")
        func fullRectMountsEverySystem() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = try document()
            let rect = CGRect(origin: .zero, size: doc.size)
            #expect(ScoreView.mountedSystemIndices(of: doc, in: rect) == Array(doc.systems.indices))
        }

        @Test("a rect below the document mounts nothing")
        func rectPastTheEndMountsNothing() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = try document()
            let rect = CGRect(x: 0, y: doc.size.height + 50, width: doc.size.width, height: 100)
            #expect(ScoreView.mountedSystemIndices(of: doc, in: rect).isEmpty)
        }

        // MARK: - Frames

        /// frames-boxes wrapped: a VBox, a TBox and a trailing VBox between and after its systems.
        @available(macOS 15.0, *)
        private func framedDocument() throws -> LayoutDocument {
            _ = TestSupport.installApple
            let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("frames-boxes"))
            return LayoutEngine.layout(
                score: score, options: ScoreViewOptions(wrapToViewWidth: true), availableWidth: 700,
            )
        }

        @Test("no visible rect mounts every frame")
        func nilMountsEveryFrame() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = try framedDocument()
            try #require(doc.frames.count == 3)
            #expect(ScoreView.mountedFrameIndices(of: doc, in: nil) == [0, 1, 2])
        }

        /// A frame is mounted by the systems' test: the rect meets it, or starts within the point of slack below it.
        @Test("a rect over one frame mounts that frame and no other")
        func rectMountsOnlyTheFrameItMeets() throws {
            guard #available(macOS 15.0, *) else { return }
            let doc = try framedDocument()
            try #require(doc.frames.count == 3)
            let middle = doc.frames[1]
            let width = doc.size.width
            let inside = CGRect(x: 0, y: middle.originY + 1, width: width, height: max(1, middle.height - 2))
            #expect(ScoreView.mountedFrameIndices(of: doc, in: inside) == [1])
            let withinSlack = CGRect(x: 0, y: middle.bottom + 0.5, width: width, height: 1)
            #expect(ScoreView.mountedFrameIndices(of: doc, in: withinSlack) == [1])
            let pastSlack = CGRect(x: 0, y: middle.bottom + 2, width: width, height: 1)
            #expect(ScoreView.mountedFrameIndices(of: doc, in: pastSlack).isEmpty)
        }
    }
#endif
