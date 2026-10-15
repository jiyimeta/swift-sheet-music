#if os(macOS)
    import Foundation
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicMSCX
    import Testing

    /// Writes `.build/frames-digest.txt`: for each frames fixture the document's `frames` (kind, originY, height, image
    /// count). A before/after diff tool for Tasks 6–9, like W2's playback digest — no committed hash.
    /// Gated by `SM_FRAMES_DIGEST=1`.
    @Suite("FramesFixtureDigest", .serialized, .enabled(
        if: ProcessInfo.processInfo.environment["SM_FRAMES_DIGEST"] == "1",
    ))
    struct FramesFixtureDigestTests {
        private let _installApple = TestSupport.installApple

        @Test("the digest file is written for both fixtures")
        func writesDigest() throws {
            var lines: [String] = []
            let fixtures: [(name: String, load: () throws -> Score)] = [
                ("frames-boxes.mscx", { try MSCXParser.parse(MSCXFixtureLoader.mscxData("frames-boxes")) }),
                ("frames-pictures.mscz", { try MSCZReader.parse(MSCXFixtureLoader.msczData("frames-pictures")) }),
            ]
            for fixture in fixtures {
                let document = try LayoutEngine.layout(
                    score: fixture.load(), options: ScoreViewOptions(wrapToViewWidth: true), availableWidth: 700,
                )
                lines.append("\(fixture.name) systems=\(document.systems.count)")
                lines.append(contentsOf: Self.frameLines(document))
            }
            let text = lines.joined(separator: "\n")
            try text.write(toFile: ".build/frames-digest.txt", atomically: true, encoding: .utf8)
            #expect(lines.count >= 2)
        }

        /// One line per `LayoutDocument.frames` entry — empty until the frames exist (Task 5).
        private static func frameLines(_: LayoutDocument) -> [String] {
            []
        }
    }
#endif
