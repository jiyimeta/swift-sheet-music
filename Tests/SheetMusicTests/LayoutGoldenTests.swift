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
        private static let expectedDigestSHA256 =
            "2adaebc451d775b4d56d146250279a4ff60edfda18a24e9c31727429d57da966"

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
