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
    /// (`main.swift:203`), and `AdHocRender` is declared the same way.
    @available(macOS 15.0, *)
    @MainActor
    enum CorpusRender {
        static var isRequested: Bool {
            ProcessInfo.processInfo.environment["SM_RENDER_DIR"] != nil
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

            let opts = ScoreViewOptions(staffSize: 28, systemGap: 40)
            var rendered = 0
            var failed = 0
            for url in files {
                do {
                    let data = try Data(contentsOf: url)
                    let score = url.pathExtension.lowercased() == "mscx"
                        ? try SheetMusic.loadScore(mscxData: data)
                        : try SheetMusic.loadScore(msczData: data)
                    let out = outDir.appendingPathComponent(
                        url.deletingPathExtension().lastPathComponent + ".png",
                    )
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
