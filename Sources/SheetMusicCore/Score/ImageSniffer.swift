import SheetMusicFoundation

/// What the header of a PNG says about its pixels.
package struct PNGInfo: Sendable, Equatable {
    package var colorType: Int
    package var bitDepth: Int
    package var isInterlaced: Bool

    package init(colorType: Int, bitDepth: Int, isInterlaced: Bool) {
        self.colorType = colorType
        self.bitDepth = bitDepth
        self.isInterlaced = isInterlaced
    }
}

/// What `ImageSniffer` learned from an image's header.
package struct ImageInfo: Sendable, Equatable {
    package enum Format: Sendable, Equatable {
        case png
        case jpeg
    }

    package var format: Format
    package var width: Int
    package var height: Int
    /// Set for a PNG only.
    package var png: PNGInfo?
    /// The component count of a JPEG's frame header; `nil` for a PNG.
    package var jpegComponents: Int?
    /// Whether a JPEG carries an APP14 "Adobe" marker (it changes how its components are read).
    package var jpegHasAdobeMarker: Bool

    package init(
        format: Format,
        width: Int,
        height: Int,
        png: PNGInfo? = nil,
        jpegComponents: Int? = nil,
        jpegHasAdobeMarker: Bool = false,
    ) {
        self.format = format
        self.width = width
        self.height = height
        self.png = png
        self.jpegComponents = jpegComponents
        self.jpegHasAdobeMarker = jpegHasAdobeMarker
    }
}

/// Reads pixel size and format from a PNG or JPEG header, without decoding. Pure byte reads; no platform image API.
package enum ImageSniffer {
    /// The header's facts, or `nil` for a truncated header, an unknown signature, text such as SVG, or a zero
    /// dimension.
    package static func sniff(_ data: Data) -> ImageInfo? {
        let bytes = [UInt8](data)
        return sniffPNG(bytes) ?? sniffJPEG(bytes)
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    private static let ihdrTag: [UInt8] = [0x49, 0x48, 0x44, 0x52]
    private static let adobeTag: [UInt8] = [0x41, 0x64, 0x6F, 0x62, 0x65]

    private static func uint32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
    }

    private static func uint16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    /// Signature, then the `IHDR` chunk (length 13) right after it. The CRC is not read.
    private static func sniffPNG(_ bytes: [UInt8]) -> ImageInfo? {
        guard bytes.count >= 29, Array(bytes[0 ..< 8]) == pngSignature,
              uint32(bytes, 8) == 13, Array(bytes[12 ..< 16]) == ihdrTag
        else { return nil }
        let width = uint32(bytes, 16)
        let height = uint32(bytes, 20)
        guard width > 0, height > 0 else { return nil }
        return ImageInfo(
            format: .png,
            width: width,
            height: height,
            png: PNGInfo(colorType: Int(bytes[25]), bitDepth: Int(bytes[24]), isInterlaced: bytes[28] != 0),
        )
    }

    /// Walks the marker segments to the first start-of-frame, noting an APP14 "Adobe" segment on the way.
    private static func sniffJPEG(_ bytes: [UInt8]) -> ImageInfo? {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var hasAdobe = false
        var index = 2
        while index + 1 < bytes.count {
            guard bytes[index] == 0xFF else { return nil }
            let marker = bytes[index + 1]
            if marker == 0xFF {
                index += 1 // fill byte
                continue
            }
            if marker == 0x01 || (0xD0 ... 0xD8).contains(marker) || marker == 0x00 {
                index += 2 // standalone: no length
                continue
            }
            // EOI, or SOS before any frame header: nothing left to read.
            if marker == 0xD9 || marker == 0xDA { return nil }
            guard index + 4 <= bytes.count else { return nil }
            let length = uint16(bytes, index + 2)
            guard length >= 2 else { return nil }
            let payload = index + 4
            if isStartOfFrame(marker) {
                guard length >= 8, payload + 6 <= bytes.count else { return nil }
                let height = uint16(bytes, payload + 1)
                let width = uint16(bytes, payload + 3)
                guard width > 0, height > 0 else { return nil }
                return ImageInfo(
                    format: .jpeg,
                    width: width,
                    height: height,
                    jpegComponents: Int(bytes[payload + 5]),
                    jpegHasAdobeMarker: hasAdobe,
                )
            }
            if marker == 0xEE, length >= 7, payload + 5 <= bytes.count,
               Array(bytes[payload ..< payload + 5]) == adobeTag
            {
                hasAdobe = true
            }
            index += 2 + length
        }
        return nil
    }

    /// SOF0–SOF3, SOF5–SOF7, SOF9–SOF11, SOF13–SOF15; DHT (C4), JPG (C8), DAC (CC) are not frame headers.
    private static func isStartOfFrame(_ marker: UInt8) -> Bool {
        (0xC0 ... 0xCF).contains(marker) && marker != 0xC4 && marker != 0xC8 && marker != 0xCC
    }
}
