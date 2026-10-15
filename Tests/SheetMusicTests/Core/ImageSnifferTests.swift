import Foundation
@testable import SheetMusicCore
import Testing

@Suite("ImageSniffer")
struct ImageSnifferTests {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(
            TestResources.url(forResource: name, withExtension: ext),
            "fixture not bundled: \(name).\(ext)",
        )
        return try Data(contentsOf: url)
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// A PNG header only: signature, an `IHDR` chunk of the given size, nothing after it.
    private static func pngHeader(width: UInt32, height: UInt32) -> Data {
        func big(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        var bytes = pngSignature
        bytes += big(13)
        bytes += Array("IHDR".utf8)
        bytes += big(width)
        bytes += big(height)
        bytes += [8, 2, 0, 0, 0]
        return Data(bytes)
    }

    @Test func sniffsAnRGBPNG() throws {
        let data = try fixture("frames-px-rgb", "png")
        let info = try #require(ImageSniffer.sniff(data))

        #expect(info.format == .png)
        #expect(info.width == 40)
        #expect(info.height == 20)
        #expect(info.png == PNGInfo(colorType: 2, bitDepth: 8, isInterlaced: false))
        #expect(info.jpegComponents == nil)
    }

    @Test func sniffsAnRGBAPNG() throws {
        let data = try fixture("frames-px-rgba", "png")
        let info = try #require(ImageSniffer.sniff(data))

        #expect(info.format == .png)
        #expect(info.width == 40)
        #expect(info.height == 20)
        #expect(info.png == PNGInfo(colorType: 6, bitDepth: 8, isInterlaced: false))
    }

    @Test func sniffsAJPEG() throws {
        let data = try fixture("frames-photo", "jpg")
        let info = try #require(ImageSniffer.sniff(data))

        #expect(info.format == .jpeg)
        #expect(info.width == 40)
        #expect(info.height == 20)
        #expect(info.jpegComponents == 3)
        #expect(info.png == nil)
    }

    @Test func wellFormedHeaderOnlyPNGIsRead() {
        let info = ImageSniffer.sniff(Self.pngHeader(width: 7, height: 3))

        #expect(info?.width == 7)
        #expect(info?.height == 3)
    }

    private static let negativeInputs: [(label: String, data: Data)] = [
        ("empty", Data()),
        ("seven bytes", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A])),
        ("PNG signature with a 20-byte body", Data(pngSignature + [UInt8](repeating: 0, count: 20))),
        ("SVG text", Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"/>".utf8)),
        ("JPEG SOI only", Data([0xFF, 0xD8])),
        ("PNG whose IHDR says width 0", pngHeader(width: 0, height: 20)),
        ("PNG whose IHDR says height 0", pngHeader(width: 20, height: 0)),
    ]

    @Test(arguments: negativeInputs.map(\.label))
    func rejectsWhatIsNotADecodableHeader(label: String) throws {
        let input = try #require(Self.negativeInputs.first { $0.label == label })

        #expect(ImageSniffer.sniff(input.data) == nil)
    }
}
