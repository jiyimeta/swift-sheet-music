import CMediaFoundation
import Testing

/// The MP4 writer converts every frame from BGRA to NV12 (`cmf_bgra_to_nv12`: one pass, eight pixels of two rows at a
/// time with SSE2). Its output is defined as the first converter's (`cmf_bgra_to_nv12_reference`), byte for byte: the
/// same matrix, the same rounding, so the colours a video carries and the `colr` box that names them do not move.
@Suite("BGRA to NV12")
struct NV12ConversionTests {
    private static let bt709 = cmf_nv12_coefficients(
        yr: 47, yg: 157, yb: 16, ur: -26, ug: -86, ub: 112, vr: 112, vg: -102, vb: -10,
    )
    private static let bt601 = cmf_nv12_coefficients(
        yr: 66, yg: 129, yb: 25, ur: -38, ug: -74, ub: 112, vr: 112, vg: -94, vb: -18,
    )

    /// Sizes the writer meets, and widths that are not a multiple of eight, whose last columns take the scalar path.
    static let sizes: [(width: Int, height: Int)] = [(1920, 1080), (1280, 720), (854, 480), (640, 360), (14, 4), (6, 2)]

    @Test(arguments: sizes)
    func `the converter gives the reference's bytes for random pixels in both matrices`(
        size: (width: Int, height: Int),
    ) {
        var generator = SplitMix(seed: UInt64(size.width * 31 + size.height))
        let bgra = (0 ..< size.width * size.height * 4).map { index in
            index % 4 == 3 ? UInt8(255) : UInt8(truncatingIfNeeded: generator.next())
        }
        for matrix in [Self.bt709, Self.bt601] {
            let fast = Self.converted(bgra, size, matrix, reference: false)
            #expect(fast == Self.converted(bgra, size, matrix, reference: true))
        }
    }

    /// A score's frame: white paper, black and grey strokes, a coloured highlight now and then.
    @Test(arguments: sizes)
    func `the converter gives the reference's bytes for a score-like frame in both matrices`(
        size: (width: Int, height: Int),
    ) {
        var generator = SplitMix(seed: UInt64(size.width + size.height * 7))
        var bgra = [UInt8](repeating: 255, count: size.width * size.height * 4)
        for pixel in 0 ..< size.width * size.height {
            let roll = generator.next() % 100
            let value: UInt8 = roll < 85 ? 255 : roll < 95 ? 0 : UInt8(truncatingIfNeeded: generator.next())
            bgra[pixel * 4] = roll == 99 ? 40 : value
            bgra[pixel * 4 + 1] = roll == 99 ? 200 : value
            bgra[pixel * 4 + 2] = roll == 99 ? 255 : value
        }
        for matrix in [Self.bt709, Self.bt601] {
            let fast = Self.converted(bgra, size, matrix, reference: false)
            #expect(fast == Self.converted(bgra, size, matrix, reference: true))
        }
    }

    private static func converted(
        _ bgra: [UInt8], _ size: (width: Int, height: Int), _ matrix: cmf_nv12_coefficients, reference: Bool,
    ) -> [UInt8] {
        var nv12 = [UInt8](repeating: reference ? 0xAA : 0x55, count: size.width * size.height * 3 / 2)
        var coefficients = matrix
        bgra.withUnsafeBufferPointer { source in
            nv12.withUnsafeMutableBufferPointer { out in
                if reference {
                    cmf_bgra_to_nv12_reference(
                        source.baseAddress, out.baseAddress, UInt32(size.width), UInt32(size.height), &coefficients,
                    )
                } else {
                    cmf_bgra_to_nv12(
                        source.baseAddress, out.baseAddress, UInt32(size.width), UInt32(size.height), &coefficients,
                    )
                }
            }
        }
        return nv12
    }
}

/// A small seeded generator, so a failing case can be run again as it was.
private struct SplitMix {
    var state: UInt64

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
