// Generates the font-metrics table the WebAssembly bridge installs through
// `installSMuFLMetrics`.
//
// macOS-only, and deliberately so. The layout engine needs Bravura's geometric
// glyph bounds; the browser's only measurement API, Canvas2D's
// `measureText().actualBoundingBox*`, reports rasterized ink instead —
// `FontMetricsBuilder.kt` documents that quantity disagreeing with the
// geometric bounds by up to 1 sp at typical staff sizes, which is why Android
// uses `Paint.getTextPath` rather than `getTextBounds`. CoreText's
// `CTFontCreatePathForGlyph().boundingBox` is the reference Android was matched
// to, so generating from it here makes the browser agree with both other
// platforms by construction rather than by luck.
//
// The output is committed to `Web/sheet-music-web/assets/sheet-music.smft`, so
// a normal build never runs this. Re-run it when either bundled face is
// replaced:
//
//     swift run GenFontMetrics Web/sheet-music-web/assets/sheet-music.smft
//
// Byte layout: see `SheetMusicBridgeCore/FontMetricsTable.swift`. SMFT v4,
// little-endian, values in points at a 1000 pt reference size.
//
// TWO faces, since v4. Bravura's ascent and descent went into the table in v3
// because `(ascent − descent) / 2` is how every glyph-centring call site finds
// its baseline, and without the pair the provider fell back to the stub's
// 0.85 / 0.25 em and centred articulations 1.2 sp off. The same argument
// applies to Edwin, which is the face MuseScore's `Sid::*FontFace` defaults all
// name: without a measured text face, every advance in a rehearsal-mark frame,
// harmony or lyric came from `StubFontMetricsProvider.advanceEm`'s bucket
// estimate, and the row's vertical position from 0.85 / 0.25 em against
// Edwin's measured 0.737 / 0.263 with no line gap at all.
import CoreGraphics
import CoreText
import Foundation
import SheetMusicLayout
import SheetMusicLayoutApple

enum GenFontMetrics {
    static let referenceSize: Double = 1000
    static let magic: UInt32 = 0x534D_4654 // "SMFT"
    static let tableVersion: UInt32 = 4

    /// Bravura's BMP private-use area, as SMuFL defines it. Same range as
    /// `FontMetricsBuilder.kt` walks on Android.
    static let smuflPUARange: ClosedRange<UInt32> = 0xE000 ... 0xF8FF
    /// Edwin is a text face with no single defining block, so the walk is the
    /// whole BMP and the font's own cmap decides what survives — 871
    /// codepoints as of Edwin 0.54 (Latin, Greek, Cyrillic, punctuation,
    /// arrows, math, box drawing, `♭♮♯`, ligatures, and Edwin's own PUA).
    /// `FontMetricsBuilder.kt` walks the identical range.
    static let textRange: ClosedRange<UInt32> = 0x0020 ... 0xFFFF

    static let edwinFamilyName = "Edwin"

    /// The repo's own Edwin. `Scripts/web-fonts.sh` already treats this copy as
    /// the source of `edwin-roman.woff2`, so measuring it here is measuring the
    /// file the browser and Android actually draw with.
    static let edwinFontURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Tools/GenFontMetrics
        .deletingLastPathComponent() // Tools
        .deletingLastPathComponent() // repo root
        .appendingPathComponent(
            "Android/SheetMusicComposeAndroid/src/main/assets/fonts/Edwin-Roman.otf",
        )

    struct Entry {
        let codepoint: UInt32
        let advance: Double
        let x: Double
        let y: Double
        let w: Double
        let h: Double
    }

    /// Everything one face contributes: its vertical metrics and its glyph
    /// boxes, all in points at `referenceSize`.
    struct MeasuredFace {
        let name: String
        let ascent: Double
        let descent: Double
        let leading: Double
        let entries: [Entry]
    }

    static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        exit(code)
    }

    /// The glyph CoreText maps `codepoint` to in `font`, or nil when the face
    /// has no glyph for it. Distinguishes "not in the cmap" from "mapped but
    /// blank": a space is mapped and has an advance worth storing, but
    /// `CTFontCreatePathForGlyph` answers nil for it just as it does for a
    /// codepoint the font never had.
    static func mappedGlyph(_ codepoint: UInt32, in font: CTFont) -> CGGlyph? {
        guard codepoint <= 0xFFFF else { return nil }
        var characters: [UniChar] = [UniChar(codepoint)]
        var glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, 1),
              glyphs[0] != 0
        else { return nil }
        return glyphs[0]
    }

    /// - Parameter minimumGlyphs: a face that failed to register resolves to
    ///   the system font, which is a silent CoreText fallback rather than an
    ///   error. Both the family-name check below and this floor exist to turn
    ///   "the table is quietly measuring Helvetica" into a build failure.
    @available(macOS 15.0, *)
    static func measure(
        face: String,
        candidates: ClosedRange<UInt32>,
        keepBlanks: Bool,
        minimumGlyphs: Int,
    ) -> MeasuredFace {
        let ct = CTFontCreateWithName(face as CFString, referenceSize, nil)
        let resolved = CTFontCopyFamilyName(ct) as String
        guard resolved == face else {
            fail(
                "\(face) is not registered — CoreText resolved it to \(resolved), "
                    + "so the table would carry that font's metrics",
                code: 3,
            )
        }
        let provider = AppleFontMetricsProvider()
        let font = LayoutFont(face: face, pointSize: referenceSize)

        var entries: [Entry] = []
        entries.reserveCapacity(2048)
        for codepoint in candidates {
            guard let scalar = Unicode.Scalar(codepoint) else { continue }
            guard mappedGlyph(codepoint, in: ct) != nil else { continue }
            let advance = Double(
                provider.typographicWidth(text: String(scalar), font: font),
            )
            let bbox = provider.glyphPathBoundingBox(
                font: font, codepoint: UInt16(codepoint),
            )
            if keepBlanks {
                // A text face's blanks carry the advances that space out a
                // lyric; dropping them would send every space back to the
                // stub's 0.3 em guess.
                guard advance > 0 || (bbox?.width ?? 0) > 0 else { continue }
            } else {
                guard advance > 0, let bbox, bbox.width > 0, bbox.height > 0
                else { continue }
            }
            // A mapped-but-blank glyph stores a zero box: the entry exists for
            // its advance, and the reader skips zero-area boxes when it unions
            // ink.
            let inked: CGRect? = if let bbox, bbox.width > 0, bbox.height > 0 {
                bbox
            } else {
                nil
            }
            entries.append(
                Entry(
                    codepoint: codepoint,
                    advance: advance,
                    // CoreText's path bounding box is already y-up with the
                    // baseline at y = 0, which is the convention
                    // `FontMetricsTable` expects. No flip here, unlike the
                    // Android producer, which reads y-down `Path` bounds and
                    // negates.
                    x: inked.map { Double($0.minX) } ?? 0,
                    y: inked.map { Double($0.minY) } ?? 0,
                    w: inked.map { Double($0.width) } ?? 0,
                    h: inked.map { Double($0.height) } ?? 0,
                ),
            )
        }
        guard entries.count >= minimumGlyphs else {
            fail(
                "only \(entries.count) glyphs measured for \(face); "
                    + "expected at least \(minimumGlyphs)",
                code: 4,
            )
        }
        return MeasuredFace(
            name: face,
            ascent: Double(provider.ascent(font: font)),
            descent: Double(provider.descent(font: font)),
            leading: Double(provider.leading(font: font)),
            entries: entries,
        )
    }

    @available(macOS 15.0, *)
    static func measureAll() -> [MeasuredFace] {
        guard BravuraFont.register else {
            fail("Bravura failed to register with CoreText", code: 3)
        }
        guard FileManager.default.fileExists(atPath: edwinFontURL.path) else {
            fail("no Edwin at \(edwinFontURL.path)", code: 3)
        }
        guard !SheetMusicFonts.register(urls: [edwinFontURL]).isEmpty else {
            fail("Edwin failed to register with CoreText", code: 3)
        }
        return [
            measure(
                face: BravuraFont.familyName,
                candidates: smuflPUARange,
                keepBlanks: false,
                minimumGlyphs: 1000,
            ),
            measure(
                face: edwinFamilyName,
                candidates: textRange,
                keepBlanks: true,
                minimumGlyphs: 500,
            ),
        ]
    }

    static func encode(_ faces: [MeasuredFace]) -> Data {
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
        func appendString(_ s: String) {
            let bytes = Array(s.utf8)
            appendU32(UInt32(bytes.count))
            out.append(contentsOf: bytes)
        }

        appendU32(magic)
        appendU32(tableVersion)
        appendF64(referenceSize)
        appendU32(UInt32(faces.count))
        for face in faces {
            appendString(face.name)
            appendF32(face.ascent)
            appendF32(face.descent)
            appendF32(face.leading)
            appendU32(UInt32(face.entries.count))
            for entry in face.entries {
                appendU32(entry.codepoint)
                appendF32(entry.advance)
                appendF32(entry.x)
                appendF32(entry.y)
                appendF32(entry.w)
                appendF32(entry.h)
            }
        }
        return out
    }

    static func run() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: GenFontMetrics <output.smft>\n".utf8))
            exit(2)
        }
        guard #available(macOS 15.0, *) else {
            fail("macOS 15 or newer required", code: 1)
        }
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let faces = measureAll()
        let out = encode(faces)
        do {
            try out.write(to: outputURL)
        } catch {
            fail("could not write \(outputURL.path): \(error)", code: 5)
        }
        for face in faces {
            print(
                "\(face.name): \(face.entries.count) glyphs, ascent \(face.ascent), "
                    + "descent \(face.descent), leading \(face.leading)",
            )
        }
        print("wrote \(out.count) bytes to \(outputURL.path)")
    }
}

GenFontMetrics.run()
