import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicZip
import Testing

/// **The 2-pass idempotency gate.** Decode a score, encode it (pass 1), decode THAT, encode again (pass 2):
/// pass 1 and pass 2 must be byte-identical.
///
/// ## What this catches that nothing else does
///
/// Pass 1 differing from the ORIGINAL file is expected and legitimate — the encoder writes tags MuseScore's own
/// files omit, and every existing round-trip test compares `Score` values rather than bytes for exactly that
/// reason (`MSCXRoundTripTests`). Pass 1 differing from pass 2 is a different animal: it means a save is not a
/// fixed point, so every save mutates the file further, and a user who opens and saves five times gets five
/// different files.
///
/// The bug class is a decoder and an encoder that walk the same cursor and disagree about it. The real one:
/// `<location>` tick cursors were walked independently by `MSCXDecoder` and `MSCXEncoder`, each moving the
/// cursor permanently, so pass 2 re-spelled positions pass 1 had already normalized. `Score`-equality
/// round-trip tests are blind to it — both passes decode to the same score; it is the BYTES that drift. Byte
/// comparison against the original is blind to it too, because that comparison never passes in the first place.
///
/// ## Two layers
///
/// - **Always-on** (`MSCXIdempotencyTests`): the repo's own committed fixtures, chosen for the shapes that
///   have moved the encoder's output. Fast, no environment setup, runs in CI.
/// - **Opt-in corpus** (`MSCXIdempotencySweep`): the same comparison over a directory of real scores, named by
///   the `SM_MSCX_IDEMPOTENCY_DIR` environment variable and skipped entirely when it is unset. No corpus path
///   is committed here; the variable carries it. See `docs/development/mscx-idempotency.md`.
enum MSCXIdempotency {
    /// The two encoder passes for one already-decoded score.
    ///
    /// Pass 2 decodes pass 1's OUTPUT rather than the original bytes — that is the whole point. Encoding the
    /// same in-memory score twice would compare the encoder with itself and pass unconditionally.
    static func passes(of score: Score) throws -> (first: Data, second: Data) {
        let first = try MSCXEncoder.encode(score)
        let second = try MSCXEncoder.encode(MSCXParser.parse(first))
        return (first, second)
    }

    /// The comparison itself, reported so a failure names the file and the first byte that moved rather than
    /// dumping two whole XML documents into the transcript.
    static func expectFixedPoint(_ score: Score, named name: String) throws {
        let (first, second) = try passes(of: score)
        guard first != second else { return }
        Issue.record("\(name): encode is not idempotent — \(difference(first, second))")
    }

    /// Where two encodings first diverge, as a line number plus both lines. A byte offset alone is unusable on
    /// a 4000-line MSCX; the line is what a reader can go and look at.
    ///
    /// The pass/fail decision above is byte-level, but `lines(of:)` trims whitespace to line the two documents
    /// up for a readable diff — so an INDENTATION-only divergence, or non-UTF-8 output (`String(bytes:encoding:)`
    /// answers `nil` and both sides read as empty), can make every trimmed line compare equal while the raw
    /// bytes still differ. Falls back to the first differing BYTE offset and a short hex/context window then,
    /// so the message still names something a reader can go and look at instead of "0 lines vs 0 lines".
    static func difference(_ first: Data, _ second: Data) -> String {
        let left = lines(of: first)
        let right = lines(of: second)
        for index in 0 ..< min(left.count, right.count) where left[index] != right[index] {
            return "line \(index + 1): pass1 <\(left[index])> vs pass2 <\(right[index])>"
        }
        if left.count != right.count {
            return "pass1 has \(left.count) lines, pass2 has \(right.count)"
        }
        return byteOffsetDifference(first, second)
    }

    /// The fallback when a line-level diff cannot name a line — either the two documents are byte-different but
    /// line-identical after whitespace trimming, or one/both are not valid UTF-8. Reports the first byte index
    /// that differs plus a short hex window of context around it on each side.
    private static func byteOffsetDifference(_ first: Data, _ second: Data) -> String {
        let firstBytes = [UInt8](first)
        let secondBytes = [UInt8](second)
        guard let offset = (0 ..< min(firstBytes.count, secondBytes.count))
            .first(where: { firstBytes[$0] != secondBytes[$0] })
        else {
            return "pass1 is \(firstBytes.count) bytes, pass2 is \(secondBytes.count) bytes, "
                + "identical up to the shorter length"
        }
        return "byte offset \(offset): pass1 <\(hexWindow(firstBytes, around: offset))> "
            + "vs pass2 <\(hexWindow(secondBytes, around: offset))>"
    }

    /// Up to 8 bytes of hex context centered on `offset`, so a non-UTF-8 or whitespace-only divergence still
    /// points at something concrete.
    private static func hexWindow(_ bytes: [UInt8], around offset: Int) -> String {
        let lower = max(0, offset - 4)
        let upper = min(bytes.count, offset + 4)
        return bytes[lower ..< upper].map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func lines(of data: Data) -> [String] {
        let text = String(bytes: data, encoding: .utf8) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// The always-on layer. Every fixture here is named with the reason it is here — a shape that has moved the
/// encoder's output, so a future change to that writer is what this gate is watching for.
@Suite("MSCX 2-pass idempotency")
struct MSCXIdempotencyTests {
    /// - `testVoltaTemp` — a `<Tempo>` system element plus a `<Volta>` whose `<next><location>` is exactly the
    ///   relative-position spelling the `<location>` cursor bug corrupted on the second pass.
    /// - `testSingleNoteDynamics` — the densest spanner fixture in the repo: hairpins with `<next>` offsets and
    ///   per-note dynamics, i.e. many `<location>` writes in one file.
    /// - `slur_ms4_resave` — slurs, whose begin side lives in `Chord.spanners` rather than as its own element;
    ///   the shape `SetTimeSignature`'s re-bar walk and `MeasureStructure.adjustSpannerOffsets` both had to be
    ///   taught, and the one an element-only walk silently skips.
    /// - `own/grace-notes` — the repo's only `<Tuplet>` fixture, and it carries grace notes too: tuplet ranges
    ///   are index-based and grace chords are re-ordered on write (`graceNotesAfter()` is emitted in reverse),
    ///   so both are re-derived rather than copied.
    /// - `grace_after` — after-grace notes specifically, which the encoder writes BEFORE their parent chord
    ///   with `<grace>` as an absolute value while `<notes>` is a delta; the placement rule most likely to
    ///   drift between passes.
    /// - `multiPartMixedStaves` — several parts and staves, so the per-staff tick cursors have to agree with
    ///   each other and not just with themselves.
    /// - `spanner_offsets_score_end` — a spanner ending at the score end, the boundary where MuseScore's own
    ///   `measureByTick` steps BACK onto the last measure instead of past it.
    /// - `slur_ms3_exchangevoices` — 4 `<voice>` nodes and 6 `<location>` nodes across 3 measures, none of them
    ///   single-voice. The gate's other fixtures are ALL single-voice (`<voice>` count == `<Measure>` count,
    ///   measured — every one of them), so without this one the gate could not even in principle catch a bug
    ///   confined to a second voice. **What this fixture actually covers: multi-voice `<location>` MARKER
    ///   writing** — the six `<location>` nodes here are all `<Spanner><next>/<prev>` slur begin/end markers
    ///   spanning several voices in one measure (`MSCXEncoder+ChordSlur.swift`'s `pendingSlurEnds` walk, and
    ///   the cross-voice `<voices>` field it deliberately does NOT place — see that file's doc comment).
    ///   `8623592d` (`fix(mscx): walk one cursor through voice-level <location> jogs`) is cited here as the
    ///   MOTIVATION for adding a multi-voice fixture to this gate at all, not as something this specific
    ///   fixture reproduces: that commit's bug was in bare voice-level jog `<location>` elements
    ///   (`VoiceElement.locationShift`), and this fixture has none — every `<location>` in it sits inside a
    ///   `<Spanner>`. **The literal voice-jog mechanism is NOT covered by any committed fixture.** Measured,
    ///   not assumed: a `.locationShift` in a non-zero voice was built and probed directly (decode → encode →
    ///   decode → encode stayed byte-identical even with the encoder's cursor-advance for `.locationShift`
    ///   disabled outright), because the only channel through which that cursor's value reaches the written
    ///   bytes — interleaving a system element (`<Tempo>` / `<StaffText>` / …) at its position — is wired to
    ///   voice 0 only (`MSCXEncoder+Measure.swift`: `index == 0 ? voice0SystemElements : []`), and neither a
    ///   slur end marker (`MSCXDecoder+Chord.swift`: "the `<prev>` side carries no model state — the encoder
    ///   recomputes it") nor a tie's `<location>` (`MSCXEncoder+Voice+Ties.swift`'s `forwardTieDelta` /
    ///   `backwardTieDelta` depend only on chord duration and the PREVIOUS MEASURE's carry, never the
    ///   within-measure cursor) reads that cursor's value either. Covering the literal mechanism would need
    ///   the encoder taught to interleave a system element into a non-zero voice too, plus a fixture — not
    ///   just a fixture on its own.
    /// - `guitarbend_simple` — 6 `<location>` nodes, and the most recently reworked endpoint writer
    ///   (`bb3474ae feat(mscx): encode GuitarBend spanners with real endpoint locations`) had no fixture here at
    ///   all until now.
    @Test("committed MSCX fixtures encode to a fixed point", arguments: [
        "testVoltaTemp",
        "testSingleNoteDynamics",
        "slur_ms4_resave",
        "grace-notes",
        "grace_after",
        "multiPartMixedStaves",
        "spanner_offsets_score_end",
        "slur_ms3_exchangevoices",
        "guitarbend_simple",
    ])
    func mscxFixtureIsAFixedPoint(_ name: String) throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData(name))
        try MSCXIdempotency.expectFixedPoint(score, named: "\(name).mscx")
    }

    /// The zipped container reaches the same encoder through `MSCZReader`, and `test_lyrics` carries lyrics —
    /// per-note text the encoder writes back out from a separate model array.
    @Test("a committed MSCZ fixture encodes to a fixed point")
    func msczFixtureIsAFixedPoint() throws {
        let score = try MSCZReader.parse(MSCXFixtureLoader.msczData("test_lyrics"))
        try MSCXIdempotency.expectFixedPoint(score, named: "test_lyrics.mscz")
    }

    /// A hidden beam is written as a `<Beam><visible>0</visible></Beam>` sibling placed just before its leading
    /// chord — a tag SYNTHESIZED on write from `Chord.beamVisible` rather than carried through from a decoded
    /// node, which is precisely the kind of writer that can emit a second copy on a second pass.
    ///
    /// Built by perturbing a decoded fixture because no committed fixture carries one: every `<Beam>` in
    /// `Tests/SheetMusicTests/Resources/` is a `<l1>`/`<l2>` stem-position node, none of them hidden (measured,
    /// not assumed). `BeamVisibleRoundTripTests` pins the tag's placement; this pins that writing it twice
    /// changes nothing.
    @Test("a hidden beam encodes to a fixed point")
    func hiddenBeamIsAFixedPoint() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("legacybend_ms3_play_and_beams"))
        var hidden = 0
        for partIndex in score.parts.indices {
            for staffIndex in score.parts[partIndex].staves.indices {
                let measures = score.parts[partIndex].staves[staffIndex].measures
                for measureIndex in measures.indices {
                    hidden += Self.hideFirstBeam(
                        in: &score.parts[partIndex].staves[staffIndex].measures[measureIndex],
                    )
                }
            }
        }
        #expect(hidden > 0, "the fixture no longer has a chord to hide a beam on")
        try MSCXIdempotency.expectFixedPoint(score, named: "legacybend_ms3_play_and_beams.mscx + hidden beam")
    }

    /// Clears `beamVisible` on the measure's first chord, and answers how many it changed — the count is what
    /// keeps this from being a test that silently does nothing.
    private static func hideFirstBeam(in measure: inout Measure) -> Int {
        for voiceIndex in measure.voices.indices {
            let elements = measure.voices[voiceIndex].elements
            for elementIndex in elements.indices {
                guard case var .chord(chord) = elements[elementIndex], chord.beamVisible else { continue }
                chord.beamVisible = false
                measure.voices[voiceIndex].elements[elementIndex] = .chord(chord)
                return 1
            }
        }
        return 0
    }
}

/// The opt-in corpus layer: the same 2-pass comparison over every `.mscx` / `.mscz` under the directory named
/// by `SM_MSCX_IDEMPOTENCY_DIR`, recursively. Disabled — not failed, not skipped-with-a-warning — when the
/// variable is unset, following `PDFImportProbeHarnessTests` and `FormatGTests`' soak.
///
///     SM_MSCX_IDEMPOTENCY_DIR=~/path/to/scores swift test --filter MSCXIdempotencySweep
///
/// A file that will not DECODE is reported and skipped rather than failed: a corpus of real scores contains
/// MuseScore 1.x files this reader does not claim to open, and a gate that fails on them says nothing about
/// idempotency. A file that decodes but whose ENCODE throws is a different animal — that is the encoder itself
/// breaking on real input, not an unsupported format — so it is counted separately as `failed` and makes the
/// sweep fail: a `try?` that folded a throwing encode into "no difference to report" would let a broken encoder
/// hide inside `differing=0`, which is exactly the kind of unverified green result this gate exists to catch.
/// The run prints the loaded / unreadable / failed / differing counts, because "no failure was reported" and
/// "it compared 668 scores" are different facts.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["SM_MSCX_IDEMPOTENCY_DIR"] != nil))
struct MSCXIdempotencySweep {
    @Test("every score in the corpus encodes to a fixed point")
    func corpusIsAFixedPoint() throws {
        let raw = try #require(ProcessInfo.processInfo.environment["SM_MSCX_IDEMPOTENCY_DIR"])
        let root = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        let files = Self.scoreFiles(under: root)
        #expect(!files.isEmpty, "no .mscx / .mscz found under \(root.path)")

        var loaded = 0
        var unreadable: [String] = []
        var failed: [String] = []
        var differing: [String] = []
        for file in files {
            guard let score = try? Self.score(at: file) else {
                unreadable.append(file.lastPathComponent)
                continue
            }
            loaded += 1
            do {
                let passes = try MSCXIdempotency.passes(of: score)
                guard passes.first != passes.second else { continue }
                differing.append(
                    "\(file.lastPathComponent): \(MSCXIdempotency.difference(passes.first, passes.second))",
                )
            } catch {
                failed.append("\(file.lastPathComponent): \(error)")
            }
        }

        print("[mscx-idempotency] files=\(files.count) loaded=\(loaded) "
            + "unreadable=\(unreadable.count) failed=\(failed.count) differing=\(differing.count)")
        for name in unreadable.prefix(20) {
            print("[mscx-idempotency][unreadable] \(name)")
        }
        for line in failed.prefix(20) {
            print("[mscx-idempotency][failed] \(line)")
        }
        for line in differing.prefix(20) {
            print("[mscx-idempotency][differs] \(line)")
        }
        #expect(failed.isEmpty, "\(failed.count) of \(loaded) scores decoded but threw on re-encode")
        #expect(differing.isEmpty, "\(differing.count) of \(loaded) scores re-encode differently on pass 2")
    }

    private static func score(at url: URL) throws -> Score {
        let data = try Data(contentsOf: url)
        return url.pathExtension.lowercased() == "mscz"
            ? try MSCZReader.parse(data)
            : try MSCXParser.parse(data)
    }

    private static func scoreFiles(under root: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        )
        let found = (enumerator?.allObjects as? [URL] ?? []).filter {
            ["mscx", "mscz"].contains($0.pathExtension.lowercased())
        }
        return found.sorted { $0.path < $1.path }
    }
}
