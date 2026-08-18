// Generates the SMuFL glyph-metrics table the WebAssembly bridge installs
// through `installSMuFLMetrics`.
//
// macOS-only, and deliberately so. The layout engine needs Bravura's geometric
// glyph bounds; the browser's only measurement API, Canvas2D's
// `measureText().actualBoundingBox*`, reports rasterized ink instead —
// `BravuraMetricsBuilder.kt` documents that quantity disagreeing with the
// geometric bounds by up to 1 sp at typical staff sizes, which is why Android
// uses `Paint.getTextPath` rather than `getTextBounds`. CoreText's
// `CTFontCreatePathForGlyph().boundingBox` is the reference Android was matched
// to, so generating from it here makes the browser agree with both other
// platforms by construction rather than by luck.
//
// The output is committed to `Web/sheet-music-web/assets/bravura.smft`, so a
// normal build never runs this. Re-run it when Bravura is replaced:
//
//     swift run GenBravuraMetrics Web/sheet-music-web/assets/bravura.smft
//
// Byte layout: see `SheetMusicBridgeCore/SMuFLMetricsTable.swift`. SMFT v2,
// little-endian, values in points at a 1000 pt reference size.
import Foundation
import SheetMusicLayout
import SheetMusicLayoutApple

enum GenBravuraMetrics {
    static let referenceSize: Double = 1000
    static let magic: UInt32 = 0x534D_4654 // "SMFT"
    static let tableVersion: UInt32 = 2
    /// Bravura's BMP private-use area, as SMuFL defines it. Same range as
    /// `BravuraMetricsBuilder.kt` walks on Android.
    static let puaRange: ClosedRange<UInt32> = 0xE000 ... 0xF8FF
    /// A Bravura that failed to register resolves to the system font, which
    /// measures a handful of glyphs rather than thousands. Refusing below this
    /// turns "the table is silently mostly-empty" into a build failure.
    static let minimumExpectedGlyphs = 1000

    struct Entry {
        let codepoint: UInt32
        let advance: Double
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(code)
    }

    @available(macOS 15.0, *)
    static func measureEntries() -> [Entry] {
        guard BravuraFont.register else {
            fail("Bravura failed to register with CoreText", code: 3)
        }
        let provider = AppleFontMetricsProvider()
        let font = LayoutFont(face: BravuraFont.familyName, pointSize: referenceSize)

        var entries: [Entry] = []
        entries.reserveCapacity(2048)
        for codepoint in puaRange {
            guard let scalar = Unicode.Scalar(codepoint) else { continue }
            let advance = Double(
                provider.typographicWidth(text: String(Character(scalar)), font: font),
            )
            guard advance > 0 else { continue }
            guard let bbox = provider.glyphPathBoundingBox(
                font: font, codepoint: UInt16(codepoint),
            ), bbox.width > 0, bbox.height > 0 else { continue }
            entries.append(
                Entry(
                    codepoint: codepoint,
                    advance: advance,
                    // CoreText's path bounding box is already y-up with the
                    // baseline at y = 0, which is the convention
                    // `SMuFLMetricsTable` expects. No flip here, unlike the
                    // Android producer, which reads y-down `Path` bounds and
                    // negates.
                    x: Double(bbox.minX), y: Double(bbox.minY),
                    w: Double(bbox.width), h: Double(bbox.height),
                ),
            )
        }
        return entries
    }

    static func encode(_ entries: [Entry]) -> Data {
        var out = Data()
        func appendU32(_ v: UInt32) {
            for i in 0 ..< 4 {
                out.append(UInt8(truncatingIfNeeded: v >> (8 * i)))
            }
        }
        func appendF32(_ v: Double) {
            appendU32(Float(v).bitPattern)
        }
        func appendF64(_ v: Double) {
            let bits = v.bitPattern
            for i in 0 ..< 8 {
                out.append(UInt8(truncatingIfNeeded: bits >> (8 * i)))
            }
        }

        appendU32(magic)
        appendU32(tableVersion)
        appendF64(referenceSize)
        appendU32(UInt32(entries.count))
        for entry in entries {
            appendU32(entry.codepoint)
            appendF32(entry.advance)
            appendF32(entry.x)
            appendF32(entry.y)
            appendF32(entry.w)
            appendF32(entry.h)
        }
        return out
    }

    static func run() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: GenBravuraMetrics <output.smft>\n".utf8))
            exit(2)
        }
        guard #available(macOS 15.0, *) else {
            fail("macOS 15 or newer required", code: 1)
        }
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let entries = measureEntries()
        guard entries.count >= minimumExpectedGlyphs else {
            fail(
                "only \(entries.count) glyphs measured; Bravura is probably not loaded",
                code: 4,
            )
        }
        let out = encode(entries)
        do {
            try out.write(to: outputURL)
        } catch {
            fail("could not write \(outputURL.path): \(error)", code: 5)
        }
        print("wrote \(entries.count) glyphs, \(out.count) bytes to \(outputURL.path)")
    }
}

GenBravuraMetrics.run()
