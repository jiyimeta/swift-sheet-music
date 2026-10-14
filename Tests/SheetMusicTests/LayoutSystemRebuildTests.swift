#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    import SheetMusicLayoutApple
    import SheetMusicMSCX
    import Testing

    /// `LayoutSystem(rebuilding:origin:spanners:)` hands the copy its base's `eventColumns` instead of rebuilding
    /// them. The layout golden digest does not write `eventColumns` out, so this is the check that the shortcut is
    /// exact: every system the corpus lays out — each of which went through `movedBy` and the spanner passes — must
    /// carry the columns a fresh `init` derives from its measures.
    @Suite("LayoutSystem rebuild")
    struct LayoutSystemRebuildTests {
        private static func fresh(_ system: LayoutSystem) -> LayoutSystem {
            LayoutSystem(
                origin: system.origin,
                size: system.size,
                measures: system.measures,
                staffOrigins: system.staffOrigins,
                staffAddresses: system.staffAddresses,
                staffGeometries: system.staffGeometries,
                partLabels: system.partLabels,
                brackets: system.brackets,
                spanners: system.spanners,
                sp: system.sp,
                invisibleSpanners: system.invisibleSpanners,
                showsInvisibleElements: system.showsInvisibleElements,
            )
        }

        @Test("every corpus system carries the event columns its measures derive")
        func corpusEventColumnsMatchAFreshBuild() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = SheetMusicLayoutApple.install
            let resources = URL(fileURLWithPath: "Tests/SheetMusicTests/Resources")
            let names = try FileManager.default
                .contentsOfDirectory(atPath: resources.path)
                .filter { $0.hasSuffix(".mscx") }
                .sorted()
            var systemsChecked = 0
            var columnsChecked = 0
            for name in names {
                let data = try Data(contentsOf: resources.appendingPathComponent(name))
                guard let score = try? MSCXParser.parse(data) else { continue }
                let doc = LayoutEngine.layout(
                    score: score, options: ScoreViewOptions(wrapToViewWidth: true), availableWidth: 900,
                )
                for (index, system) in doc.systems.enumerated() {
                    let expected = Self.fresh(system)
                    #expect(system.eventColumns == expected.eventColumns, "\(name) system \(index)")
                    #expect(system.maxBBoxHalfWidth == expected.maxBBoxHalfWidth, "\(name) system \(index)")
                    systemsChecked += 1
                    columnsChecked += system.eventColumns.count
                }
            }
            // A corpus that laid out nothing would pass the loop above vacuously.
            #expect(systemsChecked >= names.count)
            #expect(columnsChecked > systemsChecked)
        }

        @Test("moving a system and adding spanners keep the same event columns")
        func rebuildsKeepEventColumns() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = SheetMusicLayoutApple.install
            let url = URL(fileURLWithPath: "Tests/SheetMusicTests/Resources")
                .appendingPathComponent("midi01.mscx")
            let data = try Data(contentsOf: url)
            let score = try MSCXParser.parse(data)
            let doc = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(wrapToViewWidth: true), availableWidth: 900,
            )
            let system = try #require(doc.systems.first)
            #expect(!system.eventColumns.isEmpty)
            let moved = system.movedBy(dy: 37)
            #expect(moved.origin.y == system.origin.y + 37)
            #expect(moved.eventColumns == Self.fresh(moved).eventColumns)
            let extended = system.addingSpanners([.measureNumber(text: "x", origin: .zero)])
            #expect(extended.spanners.count == system.spanners.count + 1)
            #expect(extended.eventColumns == Self.fresh(extended).eventColumns)
        }
    }
#endif
