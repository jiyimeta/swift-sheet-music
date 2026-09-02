#if os(macOS)
    import CryptoKit
    import Foundation
    import SheetMusic
    import SheetMusicCore
    import SheetMusicMIDI

    /// Batch note-on velocity digest — the before/after gate for
    /// playback-dynamics work (hairpin ramps, dynamics, articulation
    /// velocity), where a regression is audible but nothing on screen
    /// moves and no PNG changes.
    ///
    ///   SM_VELOCITY_DIR   — directory of .mscz / .mscx (required to activate)
    ///   SM_VELOCITY_OUT   — output directory (default `tmp/velocity-report`)
    ///   SM_VELOCITY_LIMIT — max files (default: all)
    ///   SM_VELOCITY_DUMP  — `1` to also write one `<name>.txt` per score
    ///                       listing every note-on, for reading the
    ///                       detail behind a digest that moved
    ///
    /// Writes `summary.tsv`: one row per score with the note-on count,
    /// a digest over every `(tick, pitch, velocity)` triple, and the
    /// velocity min / mean / max. Two runs diff cleanly — the digest
    /// says *which* scores changed, the statistics say *how far*, and
    /// the per-score dump says where.
    ///
    /// The corpus path is never committed — it is the user's own score
    /// library, same as `CorpusRender` and `Scripts/collision-report.sh`.
    ///
    /// **Reach.** Unlike `CorpusRender` / `CollisionReport`, which list
    /// immediate children only, this walk recurses: rendering MIDI
    /// costs no image work, so there is nothing to gain by making the
    /// caller flatten a corpus first. The "found N scores" line is
    /// still the cross-check against the caller's own count.
    @available(macOS 15.0, *)
    enum VelocityReport {
        static var isRequested: Bool {
            ProcessInfo.processInfo.environment["SM_VELOCITY_DIR"] != nil
        }

        private struct Digest {
            var noteOns = 0
            var minVelocity = Int.max
            var maxVelocity = Int.min
            var total = 0
            var hasher = SHA256()

            mutating func add(tick: Int, pitch: Int, velocity: Int) {
                noteOns += 1
                total += velocity
                minVelocity = min(minVelocity, velocity)
                maxVelocity = max(maxVelocity, velocity)
                hasher.update(data: Data("\(tick),\(pitch),\(velocity);".utf8))
            }

            /// Named `noteOns` rather than `count` on purpose: SwiftLint's
            /// `empty_count` autocorrect reads any `count` comparison as a
            /// Collection's and rewrites it to `isEmpty`, which this type
            /// does not have.
            var hasNotes: Bool {
                noteOns > 0
            }

            var mean: String {
                hasNotes ? String(format: "%.2f", Double(total) / Double(noteOns)) : "-"
            }

            /// One `summary.tsv` field group: the count, the digest, and
            /// the velocity range. A score with no note-ons prints `-`
            /// for the range rather than `Int.max` / `Int.min`.
            func columns() -> String {
                "\(noteOns)\t\(fingerprint)"
                    + "\t\(hasNotes ? String(minVelocity) : "-")"
                    + "\t\(mean)"
                    + "\t\(hasNotes ? String(maxVelocity) : "-")"
            }

            var fingerprint: String {
                hasher.finalize().map { String(format: "%02x", $0) }
                    .joined()
                    .prefix(16)
                    .description
            }
        }

        static func run() throws {
            let env = ProcessInfo.processInfo.environment
            guard let dir = env["SM_VELOCITY_DIR"] else { return }

            let root = URL(
                fileURLWithPath: (dir as NSString).expandingTildeInPath,
                isDirectory: true,
            )
            let outDir = URL(
                fileURLWithPath: env["SM_VELOCITY_OUT"] ?? "tmp/velocity-report",
                isDirectory: true,
            )
            try FileManager.default.createDirectory(
                at: outDir, withIntermediateDirectories: true,
            )
            let wantsDump = env["SM_VELOCITY_DUMP"] == "1"

            var files = scoreFiles(under: root)
            if let limit = env["SM_VELOCITY_LIMIT"].flatMap({ Int($0) }) {
                files = Array(files.prefix(limit))
            }
            print("found \(files.count) scores")

            var rows = ["score\tnoteOns\tfingerprint\tmin\tmean\tmax"]
            var done = 0
            var failed = 0
            for url in files {
                do {
                    let name = relativeName(of: url, under: root)
                    let (digest, dump) = try digest(of: url, keepingDump: wantsDump)
                    rows.append("\(name)\t\(digest.columns())")
                    if wantsDump {
                        let dumpURL = outDir.appendingPathComponent(
                            name.replacingOccurrences(of: "/", with: "_") + ".txt",
                        )
                        try dump.joined(separator: "\n")
                            .write(to: dumpURL, atomically: true, encoding: .utf8)
                    }
                    done += 1
                } catch {
                    failed += 1
                    // The relative path, not the basename: a score
                    // library routinely holds several copies of a piece
                    // under one name, and naming only the file sends the
                    // reader to whichever copy they find first — which
                    // may be one that loads perfectly.
                    FileHandle.standardError.write(Data(
                        "SKIP \(relativeName(of: url, under: root)): \(error)\n".utf8,
                    ))
                }
            }
            let summary = outDir.appendingPathComponent("summary.tsv")
            try rows.joined(separator: "\n")
                .appending("\n")
                .write(to: summary, atomically: true, encoding: .utf8)
            print("digested \(done), skipped \(failed) → \(summary.path)")
        }

        /// Render one score and fold every note-on into a digest. The
        /// dump rows are built only when asked for; they are one line
        /// per note-on and dwarf the digest itself on a large corpus.
        private static func digest(
            of url: URL, keepingDump: Bool,
        ) throws -> (Digest, [String]) {
            let data = try Data(contentsOf: url)
            let score = url.pathExtension.lowercased() == "mscx"
                ? try SheetMusic.loadScore(mscxData: data)
                : try SheetMusic.loadScore(msczData: data)
            let midi = try MidiRenderer.render(score: score)
            var digest = Digest()
            var dump: [String] = []
            for (trackIndex, track) in midi.tracks.enumerated() {
                for event in track.events {
                    guard case let .noteOn(channel, pitch, velocity) = event.event
                    else { continue }
                    digest.add(tick: event.tick, pitch: pitch, velocity: velocity)
                    if keepingDump {
                        dump.append(
                            "\(trackIndex)\t\(event.tick)\t\(channel)"
                                + "\t\(pitch)\t\(velocity)",
                        )
                    }
                }
            }
            return (digest, dump)
        }

        private static func scoreFiles(under root: URL) -> [URL] {
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil,
            ) else { return [] }
            return walker
                .compactMap { $0 as? URL }
                .filter { ["mscx", "mscz"].contains($0.pathExtension.lowercased()) }
                // MuseScore's own autosave husks are not scores the
                // user has: they would double-count the corpus and
                // churn the digest whenever MuseScore last ran.
                .filter { !$0.path.contains("/.mscbackup/") }
                .sorted { $0.path < $1.path }
        }

        /// Path relative to the corpus root, so the row identifies a
        /// score even when two subfolders hold the same basename.
        private static func relativeName(of url: URL, under root: URL) -> String {
            let rootPath = root.standardizedFileURL.path
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { return url.lastPathComponent }
            return String(path.dropFirst(rootPath.count).drop(while: { $0 == "/" }))
        }
    }
#endif
