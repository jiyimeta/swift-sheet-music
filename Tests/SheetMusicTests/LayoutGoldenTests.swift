#if os(macOS)
    import CryptoKit
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// Golden digest of layout output across every committed fixture.
    /// Gated by `SM_LAYOUT_GOLDEN=1`.
    ///
    /// Always writes `.build/layout-golden.txt`, then verifies it two
    /// ways:
    ///
    /// * Against `.build/layout-golden-baseline.txt` when that file is
    ///   present — a full-text comparison, so a failure names the first
    ///   differing line. The baseline is gitignored; delete it to
    ///   re-record.
    /// * Against `expectedDigestSHA256` otherwise. That constant is
    ///   committed, so the gate is real for CI and for a contributor who
    ///   has never recorded a baseline (whole-branch review finding 4:
    ///   before this, a missing baseline made the whole suite silently
    ///   return after "recorded only", leaving the branch's headline
    ///   evidence unreproducible by anyone but its author). The failure
    ///   is less readable than the full-text diff, which is why the
    ///   baseline path is kept and preferred.
    ///
    /// Re-recording is therefore a TWO-step operation: delete the
    /// baseline, re-run to write it, and update `expectedDigestSHA256`
    /// from the hash this test prints.
    @Suite("LayoutGolden", .serialized, .enabled(
        if: ProcessInfo.processInfo.environment["SM_LAYOUT_GOLDEN"] == "1",
    ))
    struct LayoutGoldenTests {
        private let _installApple = TestSupport.installApple

        /// SHA-256 of the full digest text, committed so the gate can
        /// fire without a local `.build/layout-golden-baseline.txt`.
        /// Regenerate whenever the digest legitimately changes — the
        /// test prints the actual hash on mismatch.
        ///
        /// Re-recorded 2026-09-09 for the text-entry branch. The diff
        /// against main was READ before this was updated, not
        /// regenerated to make the gate pass: all 28 changed lines are
        /// `el` lines gaining the `anchor:` field that `0357c5be` added
        /// to staff text and harmonies. Every origin, width and advance
        /// is byte-identical, so no engraving moved.
        ///
        /// It was ALREADY stale before this branch: main (9b7fe860)
        /// hashes to 426372bf3096e388ee11ca885ec44752c308334e8e6adabe2c
        /// c82f125a58c0cd, not to the value that was committed here.
        /// Whatever moved on main was never re-recorded and nobody saw
        /// it, because this suite is `.enabled(if: SM_LAYOUT_GOLDEN)`
        /// and is therefore SKIPPED by every ordinary `swift test`. A
        /// gate nothing runs is a gate that rots; that is worth fixing
        /// separately from this constant.
        ///
        /// **Where that stale value came from, traced 2026-09-10.**
        /// `e7314362…` first appears at `3348a8a2`, a MERGE commit
        /// ("Merge remote-tracking branch 'origin/main' into
        /// feature/scratch-creation-m1", 2026-08-29). No non-merge
        /// commit in this history introduces it; the last value anyone
        /// recorded deliberately was `3cbdef0b…` at `d026b7d5`. So it
        /// entered as a conflict resolution that picked a side — and
        /// the content of this file is a MEASUREMENT, where neither
        /// side of a conflict is right and the only correct resolution
        /// is to re-run and record. `git log -S` does not find it,
        /// because history simplification skips merge commits; use
        /// `git log --all -- <path>` instead. That drift
        /// (`e7314362` -> `426372bf`) is still un-diagnosed and is an
        /// open item on main, needing the tree at `3348a8a2`.
        ///
        /// **Re-recorded 2026-09-10 for the `c270a2bb` merge.**
        /// `fcf4d078` ("measure the header's key column as ink") is
        /// NOT an ancestor of `44353d0d`, the commit that recorded
        /// `7bc79806…`: the header-ink change and the text-entry batch
        /// lived on branches that could not see each other, and
        /// `c270a2bb` is the first tree containing both. Two
        /// internally-consistent lineages, only one of which had
        /// re-recorded — so the digest moves there and only there.
        ///
        /// The diff was READ, not regenerated to green. 1063 lines
        /// changed; on every one of them ONLY numbers changed (no
        /// element appeared, disappeared, or altered a non-geometric
        /// field), and every moved number is a coordinate. Splitting
        /// them: 1493 are x-only. The 18 that touch a y are 15
        /// `guitarBend.vertex` (a bend apex derived from its own
        /// horizontal span, whose endpoints' y are unchanged) and 3
        /// `chord.stemOrigin` differing in the last floating-point bit
        /// (38.284400000000005 -> 38.2844). Nothing vertical moved.
        ///
        /// That last fact also VERIFIES `169a5807`'s CHANGELOG claim
        /// that "every default reproduces the previous output
        /// exactly": injectable margins, inter-staff gap and system
        /// padding would all move y, and no y moved. That claim had
        /// been unverified since it landed.
        /// **Re-recorded for the selectable-element identity phase.**
        /// 174 lines changed, and every one of them changed only by
        /// gaining an identity field — `TextMarkKind.tempo` and
        /// `.dynamic` acquiring an `anchor:`, and `spannerSegment`
        /// acquiring its own. Checked the way the previous re-record
        /// was, but on the axis that matters when the TEXT of a line
        /// necessarily changes: every coordinate was extracted from
        /// both documents in order and compared. 4987 geometry values
        /// before, 4987 after, byte-identical. Identity was added;
        /// nothing moved.
        ///
        /// **The rule this gate cannot tell you on its own.** A green
        /// digest is silence about any element kind the corpus holds
        /// no instance of — those lines are ABSENT, not unchanged, and
        /// absence and agreement look identical from here. So before
        /// treating a green run as coverage for a kind, grep the
        /// recorded text for that kind and see whether it appears at
        /// all. Checking that on the day this was recorded, fermatas,
        /// breaths and articulations each appeared zero times, so the
        /// identity work on them rests entirely on
        /// `LayoutElementIdentityTests` and not at all on this digest.
        /// Widening the corpus is the better fix than remembering.
        /// Re-recorded again when key signatures, time signatures,
        /// barlines and voltas gained identity. Same check, same
        /// result: every coordinate extracted from both documents in
        /// order, all of them byte-identical, and the only lines that
        /// changed were those four kinds gaining an anchor.
        ///
        /// A trap worth naming, because it nearly produced a false
        /// alarm here: a spanner segment's line begins `spanner`, not
        /// `el`, so a filter written to enumerate `el <kind>(` misses
        /// voltas entirely and reports them as unchanged when they
        /// changed. Whatever tool you use to classify a diff of this
        /// file, check it against a line you KNOW moved before
        /// believing what it says about the ones you don't.
        ///
        /// **Re-recorded when tie arcs gained identity.** Paired by line
        /// index (3890 lines before and after), 24 lines changed and
        /// every one is a `spanner tieArc(` line whose only change is an
        /// appended `identity:` field: 10 ties naming their two notes,
        /// 14 slurs still `nil` until slur identity lands. Every other
        /// line is byte-identical, and all 24 arc lines in the corpus
        /// changed, so none was skipped. The classifier was checked
        /// against a line known to move: its sample tie line matched,
        /// character for character, the line derived by hand before the
        /// run.
        ///
        /// **Re-recorded when chord slurs gained identity.** The same 14
        /// slur arcs that were `identity: nil` above now name their owner
        /// and slur ordinal; 14 of 3890 lines changed, each only by that
        /// `nil` becoming a `.slur(.chord(...))` value, and no arc line is
        /// left `nil`. The corpus holds no standalone slur, so that
        /// storage form rests on `LayoutSpannerIdentityTests` alone. The
        /// sample line again matched the one derived by hand.
        ///
        /// **Re-recorded when jumps and markers gained identity.** 8 of
        /// 3890 lines changed — 4 `mk marker(` and 4 `jp jump(` lines —
        /// each only by an appended `identity:` naming the drawn staff,
        /// the measure and the list index; no other line moved. Both
        /// sample lines matched the ones derived by hand before the run.
        private static let expectedDigestSHA256 =
            "364bcd9eb6259684505776d925e3efde6f8adbdd5ab41e2b4502cce12d9dc14e"

        @Test("write digest")
        func writeDigest() throws {
            guard #available(macOS 15.0, *) else { return }
            let resources = URL(fileURLWithPath: "Tests/SheetMusicTests/Resources")
            let names = try FileManager.default
                .contentsOfDirectory(atPath: resources.path)
                .filter { $0.hasSuffix(".mscx") }
                .sorted()

            var out = ""
            for name in names {
                let data = try Data(
                    contentsOf: resources.appendingPathComponent(name),
                )
                guard let score = try? MSCXParser.parse(data) else {
                    out += "\(name)\tPARSE-FAILED\n"
                    continue
                }
                for wrap in [true, false] {
                    let opts = ScoreViewOptions(wrapToViewWidth: wrap)
                    let width = wrap
                        ? 900
                        : LayoutEngine.naturalContentWidth(
                            score: score, options: opts,
                        )
                    let doc = LayoutEngine.layout(
                        score: score, options: opts, availableWidth: width,
                    )
                    out += digest(
                        of: doc,
                        label: "\(name)\twrap=\(wrap)",
                    )
                }
            }

            let dest = URL(fileURLWithPath: ".build/layout-golden.txt")
            try out.write(to: dest, atomically: true, encoding: .utf8)
            print(
                "wrote \(dest.path): \(names.count) fixtures, "
                    + "\(out.count) bytes",
            )

            try verifyAgainstBaseline(out)
        }

        /// SHA-256 of `text`, lowercase hex.
        private func sha256(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
        }

        /// Compares `out` against `.build/layout-golden-baseline.txt` if
        /// present, recording a detailed first-diff on mismatch. Split out
        /// of `writeDigest` to keep that function under the lint length cap.
        private func verifyAgainstBaseline(_ out: String) throws {
            let hash = sha256(out)
            print("layout-golden sha256: \(hash)")
            let baseline = URL(
                fileURLWithPath: ".build/layout-golden-baseline.txt",
            )
            guard let expected = try? String(
                contentsOf: baseline, encoding: .utf8,
            ) else {
                // No local baseline — fall back to the committed hash so
                // the gate still fires (review finding 4). Delete the
                // baseline and re-run to get the readable diff back.
                print("no baseline at \(baseline.path) — checking committed hash")
                #expect(
                    hash == Self.expectedDigestSHA256,
                    Comment(
                        rawValue: "layout digest changed: sha256 \(hash) != "
                            + "committed \(Self.expectedDigestSHA256). If this "
                            + "is intended, update expectedDigestSHA256 in "
                            + "LayoutGoldenTests.swift.",
                    ),
                )
                return
            }
            // The committed hash must stay in sync with the recorded
            // baseline, or the no-baseline path above would gate on a
            // stale value that nobody ever sees fail locally.
            #expect(
                sha256(expected) == Self.expectedDigestSHA256,
                Comment(
                    rawValue: "expectedDigestSHA256 is stale relative to "
                        + "\(baseline.path): baseline hashes to "
                        + "\(sha256(expected)).",
                ),
            )
            if out != expected {
                let got = out.split(
                    separator: "\n", omittingEmptySubsequences: false,
                )
                let want = expected.split(
                    separator: "\n", omittingEmptySubsequences: false,
                )
                var firstDiff = "line count \(want.count) -> \(got.count)"
                for i in 0 ..< min(got.count, want.count)
                    where got[i] != want[i]
                {
                    firstDiff = "line \(i + 1):\n  expected: \(want[i])"
                        + "\n  actual:   \(got[i])"
                    break
                }
                Issue.record("layout output changed — \(firstDiff)")
            }
            #expect(out == expected)
        }

        /// Everything a renderer reads, in a stable textual form.
        /// `LayoutElement` and friends have no Set / Dictionary payloads,
        /// so `String(describing:)` is deterministic across runs.
        private func digest(
            of doc: LayoutDocument, label: String,
        ) -> String {
            var s = "\(label)\tsize=\(f(doc.size.width))x\(f(doc.size.height))"
                + "\tsystems=\(doc.systems.count)\n"
            s += metricsLine(doc.metrics)
            if let title = doc.titleFrame {
                s += "  title \(String(describing: title))\n"
            }
            for (i, sys) in doc.systems.enumerated() {
                s += digest(ofSystem: sys, index: i)
            }
            return s
        }

        /// `StaffMetrics`' stored properties, through `f()`. Every other
        /// `StaffMetrics` property (glyph size, stem thickness, spacing…)
        /// is a pure function of `sp`, so `sp` changing is what a
        /// renderer's mis-sizing would show up as here.
        private func metricsLine(_ metrics: StaffMetrics) -> String {
            "  metrics staffHeight=\(f(metrics.staffHeight))"
                + " sp=\(f(metrics.sp))\n"
        }

        private func digest(ofSystem sys: LayoutSystem, index i: Int) -> String {
            // `showsInvisibleElements` is not just a renderer hint: it is
            // an input to `MeasureLayerDiffPlanner.systemFrameIsUnchanged`,
            // i.e. it decides whether an edit takes the incremental
            // measure diff or a full system rebuild. Digest it.
            var s = "  sys[\(i)] origin=\(f(sys.origin.x)),\(f(sys.origin.y))"
                + " size=\(f(sys.size.width))x\(f(sys.size.height))"
                + " sp=\(f(sys.sp))"
                + " showsInvisible=\(sys.showsInvisibleElements)\n"
            for (idx, o) in sys.staffOrigins.enumerated() {
                let addr = idx < sys.staffAddresses.count
                    ? String(describing: sys.staffAddresses[idx])
                    : "MISSING"
                s += "    staffOrigin \(f(o.x)),\(f(o.y)) addr=\(addr)\n"
            }
            for l in sys.partLabels {
                s += "    label \(String(describing: l))\n"
            }
            for b in sys.brackets {
                s += "    bracket \(String(describing: b))\n"
            }
            for el in sys.spanners {
                s += "    spanner \(String(describing: el))\n"
            }
            for el in sys.invisibleSpanners {
                s += "    invSpanner \(String(describing: el))\n"
            }
            for m in sys.measures {
                s += digest(ofMeasure: m)
            }
            return s
        }

        private func digest(ofMeasure m: LayoutMeasure) -> String {
            var s = "    m[\(m.measureIndex)] origin="
                + "\(f(m.origin.x)),\(f(m.origin.y))"
                + " w=\(f(m.width)) mmr=\(String(describing: m.multiMeasureRest))"
                + " lineBreak=\(m.lineBreak) pageBreak=\(m.pageBreak)\n"
            for el in m.elements {
                s += "      el \(String(describing: el))\n"
            }
            for el in m.markers {
                s += "      mk \(String(describing: el))\n"
            }
            for el in m.jumps {
                s += "      jp \(String(describing: el))\n"
            }
            for el in m.invisibleElements {
                s += "      iv \(String(describing: el))\n"
            }
            return s
        }

        /// Normalizes the destructured system/measure geometry (origins,
        /// sizes, `sp`) to 4 decimal places so float-formatting noise
        /// can't masquerade as a layout change, while a real 0.001 pt
        /// shift still shows up.
        ///
        /// This is deliberately NOT applied inside `LayoutElement` /
        /// `LayoutBracket` / `LayoutPartLabel` / `LayoutTitleFrame`
        /// payloads — those are compared via `String(describing:)` at
        /// full precision instead. Reproducing `f()`'s clamp there would
        /// need a hand-written serializer per case, and the raw
        /// `String(describing:)` form is strictly stricter: it catches
        /// everything a clamped form would plus sub-0.0001 bit-level
        /// differences. That bias is correct for this harness — a
        /// legitimate refactor that shifts a float by less than 4
        /// decimal places inside an element payload will fail this test
        /// and must be investigated, not rounded away.
        private func f(_ v: CGFloat) -> String {
            String(format: "%.4f", v)
        }
    }
#endif
