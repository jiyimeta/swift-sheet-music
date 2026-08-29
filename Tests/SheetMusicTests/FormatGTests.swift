import Foundation
@testable import SheetMusicMSCX
import Testing

/// `FormatG` replaces `String(format: "%g", …)` on the MSCX export path, which
/// is covered by byte-identical corpus gates. These tests exist so a mismatch
/// is caught here rather than as a mysterious corpus byte diff.
///
/// The differential half uses `String(format:)` as the oracle and so only runs
/// where Foundation's printf bridge exists. It is deliberately scoped to the
/// domain the encoder can actually produce — see `exactTieDivergence` for the
/// one documented place where `FormatG` and libc disagree, and `FormatG`'s own
/// doc comment for why `FormatG` is the one that is right.
@Suite("FormatG matches printf %g")
struct FormatGTests {
    // MARK: - Fixed vectors

    @Test("known values format exactly like %g")
    func knownValues() {
        let cases: [(Double, String)] = [
            (0, "0"),
            (-0.0, "-0"),
            (7, "7"),
            (10, "10"),
            (-1.27, "-1.27"),
            (14.5, "14.5"),
            (100_000, "100000"),
            (999_999, "999999"),
            // Boundary into exponent form: X >= precision.
            (1_000_000, "1e+06"),
            // Rounds up to 1000000, which then reclassifies as exponent form.
            (999_999.5, "1e+06"),
            (1_234_567, "1.23457e+06"),
            // Exact ties resolve half-to-even on the 6th significant digit.
            (1_234_565, "1.23456e+06"),
            (1_234_575, "1.23458e+06"),
            // Small-magnitude boundary: X < -4 switches to exponent form.
            (0.0001, "0.0001"),
            (0.00001, "1e-05"),
            (0.000123456, "0.000123456"),
            // Non-terminating binaries.
            (0.1, "0.1"),
            (0.3, "0.3"),
            (24.9, "24.9"),
            (1.0 / 3.0, "0.333333"),
            // The class where re-rounding Double.description would disagree:
            // the shortest decimal ends in 5 but the binary value is below it.
            (0.1234565, "0.123456"),
            // Extremes.
            (1e100, "1e+100"),
            (.greatestFiniteMagnitude, "1.79769e+308"),
            (5e-324, "4.94066e-324"),
            (1e-100, "1e-100"),
        ]

        for (value, expected) in cases {
            #expect(FormatG.string(value) == expected, "value \(value)")
        }
    }

    @Test("non-finite values format like %g")
    func nonFinite() {
        #expect(FormatG.string(.nan) == "nan")
        #expect(FormatG.string(.infinity) == "inf")
        #expect(FormatG.string(-.infinity) == "-inf")
    }

    /// The MSCX encoder feeds `FormatG` staff-space heights, font point sizes
    /// and millimetre offsets. Pin the shapes those actually take.
    @Test("encoder-shaped values round-trip through the decoder's text form")
    func encoderShapedValues() {
        #expect(FormatG.string(10) == "10")
        #expect(FormatG.string(7.5) == "7.5")
        #expect(FormatG.string(24) == "24")
        #expect(FormatG.string(14.5) == "14.5")
        #expect(FormatG.string(-1.27) == "-1.27")
        #expect(FormatG.string(0) == "0")
        #expect(FormatG.string(283.46) == "283.46")
    }

    // MARK: - Documented divergence from libc

    #if canImport(Darwin)
        /// libc keeps trailing zeros that the C standard says to strip, when
        /// the discarded part is exactly one half — and only below a magnitude
        /// threshold, which is what gives it away as a `dtoa` fast-path
        /// artifact rather than a rule. `FormatG` always strips.
        ///
        /// Reaching this needs seven significant digits ending in an exact
        /// half, which the encoder's inputs cannot produce. Pinned so the
        /// divergence stays deliberate.
        @Test("exact-tie trailing zeros diverge from libc, deliberately")
        func exactTieDivergence() {
            let divergent: [(Double, String, String)] = [
                (1_670_005, "1.67e+06", "1.67000e+06"),
                (1_071_805, "1.0718e+06", "1.07180e+06"),
                (1.071805e9, "1.0718e+09", "1.07180e+09"),
                (1.071805e12, "1.0718e+12", "1.07180e+12"),
            ]
            for (value, ours, libc) in divergent {
                #expect(FormatG.string(value) == ours)
                #expect(String(format: "%g", value) == libc)
            }

            // Above the threshold libc strips too, so the two agree again —
            // the inconsistency is libc's, not ours.
            #expect(FormatG.string(1.071805e15) == "1.0718e+15")
            #expect(String(format: "%g", 1.071805e15) == "1.0718e+15")
        }
    #endif

    // MARK: - Differential against printf

    #if canImport(Darwin)
        /// Values the encoder can produce all come from decimal text with at
        /// most six significant digits, so nothing is ever rounded and the two
        /// implementations must agree exactly.
        @Test("six-significant-digit decimal grid matches printf")
        func decimalGrid() {
            for exponent in -10 ... 10 {
                for mantissa in 1 ... 9999 {
                    expectMatchesPrintf(decimal: mantissa, exponent: exponent)
                }
                for mantissa in stride(from: 10000, through: 999_999, by: 97) {
                    expectMatchesPrintf(decimal: mantissa, exponent: exponent)
                }
            }
        }

        /// Deterministic sweep over raw bit patterns, which reaches subnormals
        /// and exponent-form boundaries the decimal grid never hits. Random
        /// doubles have full-length expansions, so they do not land on the
        /// exact ties covered by `exactTieDivergence`.
        ///
        /// 50k patterns, not more: at ~0.3 ms per differential check this test
        /// alone set the whole run's wall clock when it swept 1M (307 s
        /// measured, with every other suite long finished). The 100M soak
        /// below is the exhaustive sweep; this default run only has to catch
        /// an implementation drift, which any window of the fixed-seed
        /// sequence does equally well.
        @Test("random bit patterns match printf")
        func randomBitPatterns() {
            var generator = SplitMix64(seed: 0x5EED_1234_ABCD_0001)
            var checked = 0
            while checked < 50000 {
                let value = Double(bitPattern: generator.next())
                guard value.isFinite else { continue }
                expectMatchesPrintf(value)
                checked += 1
            }
        }

        /// Opt-in soak for a pre-merge run: `SM_FORMATG_SOAK=1 swift test`.
        @Test(
            "soak over 100M bit patterns",
            .enabled(if: ProcessInfo.processInfo.environment["SM_FORMATG_SOAK"] == "1"),
        )
        func soak() {
            var generator = SplitMix64(seed: 0x5_0A00_0000_0001)
            var checked = 0
            while checked < 100_000_000 {
                let value = Double(bitPattern: generator.next())
                guard value.isFinite else { continue }
                expectMatchesPrintf(value)
                checked += 1
            }
        }

        private func expectMatchesPrintf(decimal mantissa: Int, exponent: Int) {
            guard let value = Double("\(mantissa)e\(exponent)") else {
                Issue.record("could not build \(mantissa)e\(exponent)")
                return
            }
            expectMatchesPrintf(value)
            expectMatchesPrintf(-value)
        }

        private func expectMatchesPrintf(_ value: Double) {
            let expected = String(format: "%g", value)
            let actual = FormatG.string(value)
            if actual != expected {
                let bits = String(value.bitPattern, radix: 16)
                Issue.record("%g mismatch for 0x\(bits): printf=\(expected) formatG=\(actual)")
            }
        }
    #endif
}

/// Fixed-seed generator so a failure is always reproducible.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
