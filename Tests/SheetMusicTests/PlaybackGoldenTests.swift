#if os(macOS)
    import CryptoKit
    import Foundation
    import SheetMusicAudioCore
    import SheetMusicCore
    import SheetMusicMIDI
    import SheetMusicMSCX
    import Testing

    /// What every playback consumer makes of every committed fixture — the SMF, the cursor timeline, the notated clock
    /// and the quarter BPM in force at each downbeat — written to `.build/playback-golden.txt`, so a refactor can be
    /// shown to change nothing and a semantic change can be read fixture by fixture. Gated by `SM_PLAYBACK_GOLDEN=1`.
    ///
    /// There is no committed hash: the file is a before/after diff, recorded on the tree before a change and compared
    /// with the one written after it (the W2 tempo plan, folino's
    /// `docs/superpowers/plans/2026-10-14-import-fidelity-w2-tempo.md`).
    ///
    /// Each track is digested with the meta events that share a tick put in a fixed order, so moving a tempo meta past
    /// a marker meta on the same tick reads as no change, while any change to a channel event, or to a meta's tick or
    /// value, still shows. The SMF's own SHA-256 is kept beside it for the cases where byte order matters.
    @Suite("PlaybackGolden", .serialized, .enabled(
        if: ProcessInfo.processInfo.environment["SM_PLAYBACK_GOLDEN"] == "1",
    ))
    struct PlaybackGoldenTests {
        @Test("write digest")
        func writeDigest() throws {
            let root = URL(fileURLWithPath: "Tests/SheetMusicTests/Resources")
            let names = try #require(FileManager.default.subpaths(atPath: root.path))
                .filter { $0.hasSuffix(".mscx") }
                .sorted()
            var out = ""
            for name in names {
                let data = try Data(contentsOf: root.appendingPathComponent(name))
                guard let score = try? MSCXParser.parse(data) else {
                    out += "\(name)\tPARSE-FAILED\n"
                    continue
                }
                out += try Self.digest(of: score, label: name)
            }
            let dest = URL(fileURLWithPath: ".build/playback-golden.txt")
            try out.write(to: dest, atomically: true, encoding: .utf8)
            print("wrote \(dest.path): \(names.count) fixtures, \(out.count) bytes")
            #expect(!names.isEmpty)
        }

        private static func digest(of score: Score, label: String) throws -> String {
            let midi = try MidiRenderer.render(score: score)
            let smf = try MidiWriter.write(midi)
            var lines = ["smf \(sha256(smf))"]
            for (index, track) in midi.tracks.enumerated() {
                lines.append("track \(index) \(sha256(Data(listing(track.events).utf8)))")
            }
            let tempos = (midi.tracks.first?.events ?? []).compactMap { timed -> String? in
                guard case let .meta(.tempo(micros)) = timed.event else { return nil }
                return "\(timed.tick):\(micros)"
            }
            lines.append("tempo \(tempos.joined(separator: " "))")
            lines.append(timelineLine(PlaybackTimeline(score: score)))
            lines.append("notated \(format(score.notatedDurationSeconds))")
            let measureCount = score.parts.first?.staves.first?.measures.count ?? 0
            let bpms = (0 ..< measureCount).map { index in
                String(format: "%.6f", score.effectiveQuarterBpm(at: .beat(measureIndex: index, tickInMeasure: 0)))
            }
            lines.append("bpm \(bpms.joined(separator: " "))")
            return lines.map { "\(label)\t\($0)\n" }.joined()
        }

        private static func timelineLine(_ timeline: PlaybackTimeline) -> String {
            let frames = timeline.frames.map { frame in
                "\(frame.tick),\(format(frame.timeSeconds)),\(format(frame.soundedTimeSeconds)),\(frame.cursor)"
            }
            return "timeline \(timeline.frames.count) \(format(timeline.totalSeconds)) "
                + sha256(Data(frames.joined(separator: ";").utf8))
        }

        /// One line per tick: the tick's meta events sorted by their description, then its other events in track order.
        private static func listing(_ events: [TimedMidiEvent]) -> String {
            var result: [String] = []
            var index = 0
            while index < events.count {
                let tick = events[index].tick
                var metas: [String] = []
                var others: [String] = []
                while index < events.count, events[index].tick == tick {
                    let described = String(describing: events[index].event)
                    if case .meta = events[index].event {
                        metas.append(described)
                    } else {
                        others.append(described)
                    }
                    index += 1
                }
                result.append("\(tick): \(metas.sorted().joined(separator: " ")) | \(others.joined(separator: " "))")
            }
            return result.joined(separator: "\n")
        }

        private static func format(_ value: Double) -> String {
            String(format: "%.9f", value)
        }

        private static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
#endif
