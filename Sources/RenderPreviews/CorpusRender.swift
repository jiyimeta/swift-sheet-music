#if os(macOS)
    import Foundation
    import SheetMusic
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicLayoutApple
    import SheetMusicMSCX
    import SheetMusicUI

    /// Batch corpus renderer — the before/after gate for layout
    /// refactors. Writes one PNG per score so two runs can be compared
    /// with `shasum`.
    ///
    ///   SM_RENDER_DIR  — directory of .mscz / .mscx (required to activate)
    ///   SM_RENDER_OUT  — output directory (default `tmp/corpus-render`)
    ///   SM_RENDER_LIMIT — max files (default: all)
    ///
    /// The corpus path is never committed — it is the user's own score
    /// library, same as `Scripts/collision-report.sh`.
    /// `@MainActor` is required: `renderScoreToPNG` is `@MainActor`
    /// (`main.swift:209-210`), and `AdHocRender` is declared the same way.
    ///
    /// **Reach.** `contentsOfDirectory` lists immediate children only —
    /// the walk is NOT recursive, matching `CollisionReport`
    /// (`CollisionReport.swift:88-89`) so the same corpus directory
    /// works for both tools. A corpus organized into subfolders must be
    /// flattened first: nested scores are invisible to this walk, with
    /// no error or warning, so the "found N scores" line printed at the
    /// start of `run()` is the only cross-check a caller has against
    /// their own count of the corpus.
    @available(macOS 15.0, *)
    @MainActor
    enum CorpusRender {
        static var isRequested: Bool {
            ProcessInfo.processInfo.environment["SM_RENDER_DIR"] != nil
        }

        /// Thrown when two input files would map to the same output
        /// path. Caught by the same per-file `catch` as parse/render
        /// failures, so a collision is reported to stderr and counted
        /// in `failed` instead of silently overwriting a prior PNG.
        private struct OutputNameCollision: Error, CustomStringConvertible {
            let name: String
            var description: String {
                "output name collision: \(name)"
            }
        }

        static func run() throws {
            let env = ProcessInfo.processInfo.environment
            guard let dir = env["SM_RENDER_DIR"] else { return }
            _ = SheetMusicLayoutApple.install

            let root = URL(
                fileURLWithPath: (dir as NSString).expandingTildeInPath,
                isDirectory: true,
            )
            let outDir = URL(
                fileURLWithPath: env["SM_RENDER_OUT"] ?? "tmp/corpus-render",
                isDirectory: true,
            )
            try FileManager.default.createDirectory(
                at: outDir, withIntermediateDirectories: true,
            )

            var files = try FileManager.default
                .contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil,
                )
                .filter { ["mscx", "mscz"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let limit = env["SM_RENDER_LIMIT"].flatMap({ Int($0) }) {
                files = Array(files.prefix(limit))
            }
            print("found \(files.count) scores")

            let opts = ScoreViewOptions(staffSize: 28, systemGap: 40)
            var rendered = 0
            var failed = 0
            // Belt and braces: the source extension is folded into the
            // output name so same-basename `.mscx`/`.mscz` pairs no
            // longer collide, AND every emitted name is tracked here so
            // any remaining collision (e.g. two entries differing only
            // by case) is reported as a failure instead of silently
            // overwriting a prior PNG — `rendered` must equal the
            // number of distinct files on disk, since the before/after
            // gate trusts that count as its denominator.
            var emittedNames: Set<String> = []
            for url in files {
                do {
                    let outputName = url.deletingPathExtension()
                        .lastPathComponent
                        + "." + url.pathExtension.lowercased() + ".png"
                    guard emittedNames.insert(outputName).inserted else {
                        throw OutputNameCollision(name: outputName)
                    }
                    let data = try Data(contentsOf: url)
                    let score = url.pathExtension.lowercased() == "mscx"
                        ? try SheetMusic.loadScore(mscxData: data)
                        : try SheetMusic.loadScore(msczData: data)
                    let out = outDir.appendingPathComponent(outputName)
                    try renderScoreToPNG(score, to: out, scale: 2, options: opts)
                    rendered += 1
                } catch {
                    failed += 1
                    FileHandle.standardError.write(Data(
                        "SKIP \(url.lastPathComponent): \(error)\n".utf8,
                    ))
                }
            }
            print("rendered \(rendered), skipped \(failed) → \(outDir.path)")
        }
    }
#endif
