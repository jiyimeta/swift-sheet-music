/// Byte-exact pure-Swift replacement for C's `printf("%g", value)`.
///
/// `String(format:)` lives in the `Foundation` umbrella, which the portable
/// targets are moving off of (the umbrella carries ICU and costs ~10 MB in a
/// WebAssembly build). MSCX export is covered by byte-identical corpus gates,
/// so the replacement has to reproduce printf exactly, not approximately.
///
/// The implementation rounds the *exact* decimal expansion of the double
/// rather than re-rounding `Double.description`. Every finite binary double
/// has a finite exact decimal expansion; rounding that with ties-to-even is
/// by definition what a correctly-rounded `%g` does. Re-rounding the shortest
/// round-trip form is subtly wrong: for a value like `0.1234565` the shortest
/// decimal ends in `5` while the binary value sits strictly below the tie, so
/// printf rounds down where a decimal tie rule rounds up.
///
/// ## Deliberate divergence from `String(format:)` on exact ties
///
/// `String(format: "%g", …)` — and the libc `printf` behind it — sometimes
/// keeps trailing zeros the C standard says to strip, but only when the
/// discarded part is exactly one half, and only below a magnitude threshold:
///
///     1.071805e6  → 1.07180e+06      1.071805e12 → 1.07180e+12
///     1.071805e9  → 1.07180e+09      1.071805e15 → 1.0718e+15
///
/// That is an artifact of `dtoa`'s internal fast path, not a documented rule,
/// and it therefore already differs between Darwin and swift-corelibs — MSCX
/// export was only ever byte-stable per platform. This implementation always
/// strips, which is what the standard specifies and is identical everywhere.
/// The divergence needs a value with exactly seven significant digits ending
/// in an exact half; the encoder's inputs (staff spaces, font sizes, millimetre
/// offsets) cannot reach it. `FormatGTests` pins both the agreement and this
/// divergence.
enum FormatG {
    /// Format `value` the way `printf("%g", value)` would.
    ///
    /// - Parameter precision: significant digits. C treats 0 as 1.
    static func string(_ value: Double, precision: Int = 6) -> String {
        let digitCount = max(1, precision)

        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }

        let sign = value.sign == .minus ? "-" : ""
        if value == 0 { return sign + "0" }

        var (digits, exponent) = exactDecimal(magnitudeOf: value)
        round(&digits, exponent: &exponent, to: digitCount)
        while digits.count > 1, digits.last == 0 {
            digits.removeLast()
        }

        return sign + present(digits, exponent: exponent, precision: digitCount)
    }

    // MARK: - Exact decimal expansion

    /// Exact decimal digits of `|value|`, most significant first, plus the
    /// decimal exponent `X` such that the value is `d1.d2d3… × 10^X`.
    ///
    /// A finite double is `m × 2^e` for integers `m`, `e`. For `e >= 0` that
    /// is the integer `m << e`. For `e < 0` it is `m × 5^k × 10^-k` where
    /// `k = -e`, so the same digit extraction works with the exponent shifted.
    private static func exactDecimal(magnitudeOf value: Double) -> (digits: [UInt8], exponent: Int) {
        let bits = value.magnitude.bitPattern
        let rawExponent = Int((bits >> 52) & 0x7FF)
        let rawSignificand = bits & 0x000F_FFFF_FFFF_FFFF

        let mantissa: UInt64
        let binaryExponent: Int
        if rawExponent == 0 {
            mantissa = rawSignificand
            binaryExponent = -1074
        } else {
            mantissa = rawSignificand | (1 << 52)
            binaryExponent = rawExponent - 1075
        }

        var limbs = BigDecimal(mantissa)
        var exponentShift = 0
        if binaryExponent >= 0 {
            limbs.multiplyByPowerOfTwo(binaryExponent)
        } else {
            let k = -binaryExponent
            limbs.multiplyByPowerOfFive(k)
            exponentShift = -k
        }

        let digits = limbs.decimalDigits()
        return (digits, digits.count - 1 + exponentShift)
    }

    // MARK: - Rounding

    /// Round `digits` to `count` significant digits, half-to-even. Digits are
    /// exact, so a trailing "5000…0" is a genuine tie and ties-to-even matches
    /// printf. A carry out of the leading digit bumps the exponent.
    ///
    private static func round(_ digits: inout [UInt8], exponent: inout Int, to count: Int) {
        guard digits.count > count else { return }

        let first = digits[count]
        let restIsZero = digits[(count + 1)...].allSatisfy { $0 == 0 }
        digits.removeSubrange(count...)

        let roundUp: Bool
        if first > 5 {
            roundUp = true
        } else if first < 5 {
            roundUp = false
        } else if !restIsZero {
            roundUp = true
        } else {
            roundUp = digits[count - 1] % 2 == 1
        }
        guard roundUp else { return }

        var index = count - 1
        while index >= 0 {
            if digits[index] == 9 {
                digits[index] = 0
                index -= 1
            } else {
                digits[index] += 1
                return
            }
        }
        digits.insert(1, at: 0)
        digits.removeLast()
        exponent += 1
    }

    // MARK: - Presentation

    /// `%g` picks exponent form when the decimal exponent is below -4 or has
    /// reached the precision; otherwise fixed form. Trailing zeros are already
    /// stripped by the caller.
    private static func present(_ digits: [UInt8], exponent: Int, precision: Int) -> String {
        let text = digits.map { String($0) }.joined()

        if exponent < -4 || exponent >= precision {
            var out = String(text.prefix(1))
            if text.count > 1 {
                out += "." + String(text.dropFirst())
            }
            let magnitude = abs(exponent)
            let padded = magnitude < 10 ? "0\(magnitude)" : "\(magnitude)"
            return out + "e" + (exponent < 0 ? "-" : "+") + padded
        }

        if exponent >= 0 {
            let integerCount = exponent + 1
            if text.count <= integerCount {
                return text + String(repeating: "0", count: integerCount - text.count)
            }
            let head = String(text.prefix(integerCount))
            return head + "." + String(text.dropFirst(integerCount))
        }

        return "0." + String(repeating: "0", count: -exponent - 1) + text
    }
}
