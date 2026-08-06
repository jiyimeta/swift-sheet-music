#if os(macOS)
    import AppKit
    import CoreGraphics
    import Foundation
    import SheetMusic
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicLayoutApple
    import SheetMusicMSCX
    import SheetMusicUI

    /// Ad-hoc single-score render path used while iterating on layout
    /// collision avoidance against MuseScore's own PDF output.
    ///
    /// Driven entirely by environment variables so it needs no argument
    /// parsing and stays out of the default sample loop:
    ///
    ///   SM_SCORE  — path to a `.mscz` / `.mscx` (required to activate)
    ///   SM_OUT    — output PNG path (default `tmp/adhoc.png`)
    ///   SM_FROM   — first measure index to keep (default 0)
    ///   SM_COUNT  — measure count to keep (default: all)
    ///   SM_WIDTH  — available width in points (default: natural width)
    ///   SM_MEASURE_NUMBERS — measure-number interval; omitted or `0`
    ///             engraves one label per system head (the default
    ///             policy), `1` labels every measure, `N` every N-th
    ///
    /// Usage:
    ///   SM_SCORE=~/Documents/.../foo.mscz SM_COUNT=8 swift run render-previews
    @available(macOS 15.0, *)
    @MainActor
    enum AdHocRender {
        static var isRequested: Bool {
            ProcessInfo.processInfo.environment["SM_SCORE"] != nil
        }

        static func run() throws {
            let env = ProcessInfo.processInfo.environment
            guard let scorePath = env["SM_SCORE"] else { return }
            _ = SheetMusicLayoutApple.install

            let url = URL(
                fileURLWithPath: (scorePath as NSString)
                    .expandingTildeInPath,
            )
            let data = try Data(contentsOf: url)
            var score = url.pathExtension.lowercased() == "mscx"
                ? try SheetMusic.loadScore(mscxData: data)
                : try SheetMusic.loadScore(msczData: data)

            let from = env["SM_FROM"].flatMap { Int($0) } ?? 0
            if let count = env["SM_COUNT"].flatMap({ Int($0) }) {
                score = sliceMeasures(of: score, from: from, count: count)
            } else if from > 0 {
                score = sliceMeasures(
                    of: score, from: from, count: .max / 2,
                )
            }

            let outPath = env["SM_OUT"] ?? "tmp/adhoc.png"
            let outURL = URL(fileURLWithPath: outPath)
            try FileManager.default.createDirectory(
                at: outURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )

            let width = env["SM_WIDTH"].flatMap { Double($0) }
            let interval = env["SM_MEASURE_NUMBERS"].flatMap { Int($0) } ?? 0
            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40,
                wrapToViewWidth: width != nil,
                measureNumbers: interval > 0
                    ? .interval(every: interval) : .systemStart,
            )
            if let width {
                try renderScoreToPNG(
                    score, to: outURL, scale: 2, options: opts,
                    availableWidth: CGFloat(width),
                )
            } else {
                try renderScoreToPNG(
                    score, to: outURL, scale: 2, options: opts,
                )
            }
            print("wrote \(outURL.path)")
        }

        /// Keep an arbitrary contiguous measure range from every staff.
        private static func sliceMeasures(
            of score: Score, from start: Int, count: Int,
        ) -> Score {
            var s = score
            for p in s.parts.indices {
                for st in s.parts[p].staves.indices {
                    let measures = s.parts[p].staves[st].measures
                    let clamped = max(0, min(start, measures.count))
                    let end = min(
                        clamped + max(0, count), measures.count,
                    )
                    s.parts[p].staves[st].measures =
                        Array(measures[clamped ..< end])
                }
            }
            return s
        }
    }
#endif
