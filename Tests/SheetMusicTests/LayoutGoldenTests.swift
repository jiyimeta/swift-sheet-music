#if os(macOS)
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    /// Golden digest of layout output across every committed fixture.
    /// Gated by `SM_LAYOUT_GOLDEN=1`.
    ///
    /// Always writes `.build/layout-golden.txt`. When
    /// `.build/layout-golden-baseline.txt` exists it also ASSERTS that
    /// the digest still matches it, so a refactor that changes rendering
    /// fails the test rather than requiring a manual `diff`. Delete the
    /// baseline to re-record.
    @Suite("LayoutGolden", .serialized, .enabled(
        if: ProcessInfo.processInfo.environment["SM_LAYOUT_GOLDEN"] == "1",
    ))
    struct LayoutGoldenTests {
        private let _installApple = TestSupport.installApple

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

        /// Compares `out` against `.build/layout-golden-baseline.txt` if
        /// present, recording a detailed first-diff on mismatch. Split out
        /// of `writeDigest` to keep that function under the lint length cap.
        private func verifyAgainstBaseline(_ out: String) throws {
            let baseline = URL(
                fileURLWithPath: ".build/layout-golden-baseline.txt",
            )
            guard let expected = try? String(
                contentsOf: baseline, encoding: .utf8,
            ) else {
                print("no baseline at \(baseline.path) — recorded only")
                return
            }
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
            if let title = doc.titleFrame {
                s += "  title \(String(describing: title))\n"
            }
            for (i, sys) in doc.systems.enumerated() {
                s += "  sys[\(i)] origin=\(f(sys.origin.x)),\(f(sys.origin.y))"
                    + " size=\(f(sys.size.width))x\(f(sys.size.height))\n"
                for o in sys.staffOrigins {
                    s += "    staffOrigin \(f(o.x)),\(f(o.y))\n"
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
                    s += "    m[\(m.measureIndex)] origin="
                        + "\(f(m.origin.x)),\(f(m.origin.y))"
                        + " w=\(f(m.width)) mmr=\(String(describing: m.multiMeasureRest))\n"
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
                }
            }
            return s
        }

        /// Fixed precision so tiny float formatting differences can't
        /// masquerade as layout changes — and so a real 0.001 pt shift
        /// still shows up.
        private func f(_ v: CGFloat) -> String {
            String(format: "%.4f", v)
        }
    }
#endif
