/// Minimal fixed-purpose big integer, base 1e9, little-endian limbs.
///
/// Exists only to give `FormatG` the exact decimal expansion of a `Double`.
/// The widest case is a subnormal, `m × 5^1074`, which is roughly 750 decimal
/// digits — about 84 limbs. Nothing here needs to be fast or general; it needs
/// to be obviously correct.
struct BigDecimal {
    /// Base 1e9 keeps every limb inside `UInt32` and makes digit extraction a
    /// plain zero-padded decimal print of each limb.
    private static let base: UInt64 = 1_000_000_000

    private var limbs: [UInt32]

    init(_ value: UInt64) {
        var value = value
        var limbs: [UInt32] = []
        repeat {
            limbs.append(UInt32(value % Self.base))
            value /= Self.base
        } while value > 0
        self.limbs = limbs
    }

    /// Multiply by `2^power`, in chunks that keep the multiplier under the base.
    mutating func multiplyByPowerOfTwo(_ power: Int) {
        var remaining = power
        while remaining > 0 {
            let step = min(remaining, 29)
            multiply(by: UInt32(1 << step))
            remaining -= step
        }
    }

    /// Multiply by `5^power`. `5^13` is the largest power of five below the base.
    mutating func multiplyByPowerOfFive(_ power: Int) {
        var remaining = power
        while remaining > 0 {
            let step = min(remaining, 13)
            var factor: UInt32 = 1
            for _ in 0 ..< step {
                factor *= 5
            }
            multiply(by: factor)
            remaining -= step
        }
    }

    private mutating func multiply(by factor: UInt32) {
        var carry: UInt64 = 0
        for index in limbs.indices {
            let product = UInt64(limbs[index]) * UInt64(factor) + carry
            limbs[index] = UInt32(product % Self.base)
            carry = product / Self.base
        }
        while carry > 0 {
            limbs.append(UInt32(carry % Self.base))
            carry /= Self.base
        }
    }

    /// Decimal digits, most significant first, without leading zeros.
    func decimalDigits() -> [UInt8] {
        var text = String(limbs[limbs.count - 1])
        for index in stride(from: limbs.count - 2, through: 0, by: -1) {
            let limb = String(limbs[index])
            text += String(repeating: "0", count: 9 - limb.count) + limb
        }
        return text.utf8.map { $0 - UInt8(ascii: "0") }
    }
}
