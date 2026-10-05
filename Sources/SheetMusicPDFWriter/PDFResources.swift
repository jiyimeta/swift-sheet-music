import SheetMusicBridgeCore
import SheetMusicFoundation
import SheetMusicLayout

/// What every page of one PDF draws with, shared across the document: the faces (each embedded once, and only if a
/// page used it) and a graphics state per alpha the pages paint in.
final class PDFResources {
    /// A line's part drawn in a fallback font: its UTF-16 range and that font.
    struct Fallback {
        let range: Range<Int>
        let font: PDFFontEmbedding
    }

    /// One per `Face`, at its raw value.
    private let faces: [PDFFontEmbedding]
    private let systemFile: @Sendable (FontWeight, Bool) -> ScorePDFFontFile?
    private let fallbackSpans: @Sendable (ScorePDFTextLine) -> [ScorePDFFallbackSpan]
    /// The platform UI face at each weight and slant asked for so far; nil where it has no file the PDF may embed.
    private var system: [SystemStyle: PDFFontEmbedding?] = [:]
    /// Every host file read so far, by key and face, in the order first used; nil for one the PDF may not embed.
    private var hostFiles: [String: PDFFontEmbedding?] = [:]
    private var hostOrder: [PDFFontEmbedding] = []
    private var fallbacks: [ScorePDFTextLine: [Fallback]] = [:]
    private var alphas: Set<UInt8> = [255]

    /// The bundled faces. Bravura for SMuFL; Edwin's four for text, picked by the text style as the Windows renderer
    /// picks them — semibold draws regular.
    enum Face: Int, CaseIterable {
        case smufl, roman, bold, italic, boldItalic

        var baseName: String {
            switch self {
            case .smufl: "Bravura"
            case .roman: "Edwin-Roman"
            case .bold: "Edwin-Bold"
            case .italic: "Edwin-Italic"
            case .boldItalic: "Edwin-BoldItalic"
            }
        }
    }

    /// The platform UI face's weight and slant for a text style: bold over semibold over regular, as the renderers
    /// read the flags.
    struct SystemStyle: Hashable {
        let weight: FontWeight
        let isItalic: Bool

        init(style: UInt8) {
            weight = if style & DrawCommand.TextStyleFlag.bold != 0 {
                .bold
            } else if style & DrawCommand.TextStyleFlag.semibold != 0 {
                .semibold
            } else {
                .regular
            }
            isItalic = style & DrawCommand.TextStyleFlag.italic != 0
        }
    }

    init(fonts: ScorePDFFonts) throws {
        faces = try Face.allCases.map { face in
            let data = switch face {
            case .smufl: fonts.smufl
            case .roman: fonts.roman
            case .bold: fonts.bold
            case .italic: fonts.italic
            case .boldItalic: fonts.boldItalic
            }
            return try PDFFontEmbedding(
                font: OpenTypeFont(data), baseName: face.baseName, resourceName: "F\(face.rawValue + 1)",
                symbolic: face == .smufl,
            )
        }
        systemFile = fonts.system
        fallbackSpans = fonts.fallback
    }

    /// The face a font id draws in under `style` (`DrawCommand.TextStyleFlag` bits): the platform UI face for
    /// `.system` text when the host gave a file for that style the PDF may embed, Edwin otherwise.
    func font(_ fontId: DrawProgram.FontID, style: UInt8) -> PDFFontEmbedding {
        if fontId == .system, let system = systemFace(SystemStyle(style: style)) { return system }
        let bold = style & DrawCommand.TextStyleFlag.bold != 0
        let italic = style & DrawCommand.TextStyleFlag.italic != 0
        let face: Face = switch (fontId, bold, italic) {
        case (.smufl, _, _): .smufl
        case (_, true, true): .boldItalic
        case (_, true, false): .bold
        case (_, false, true): .italic
        case (_, false, false): .roman
        }
        return faces[face.rawValue]
    }

    /// The UI face for `style`, read the first time a page asks for it.
    private func systemFace(_ style: SystemStyle) -> PDFFontEmbedding? {
        if let known = system[style] { return known }
        let embedding = systemFile(style.weight, style.isItalic).flatMap(hostFont)
        system[style] = .some(embedding)
        return embedding
    }

    /// For a line drawn in `face` with characters it lacks, the parts the host draws in other fonts — asked once per
    /// line and style; none when `face` has every character, or the host gives no font the PDF may embed.
    func fallbacks(
        _ line: String, drawnIn face: PDFFontEmbedding, fontId: DrawProgram.FontID, style: UInt8,
    ) -> [Fallback] {
        guard line.unicodeScalars.contains(where: { face.font.glyph(for: $0.value) == 0 }) else { return [] }
        let styled = SystemStyle(style: style)
        let request = ScorePDFTextLine(
            text: line, isSystemFace: fontId == .system, weight: styled.weight, isItalic: styled.isItalic,
        )
        if let known = fallbacks[request] { return known }
        let found = fallbackSpans(request).compactMap { span in
            hostFont(span.font).map { Fallback(range: span.utf16Range, font: $0) }
        }
        fallbacks[request] = found
        return found
    }

    /// The embedding of a file the host handed over, made the first time its key and face come up: named after its
    /// PostScript name, and given the resource names after the bundled faces' (`F6`, …) in the order first used. Nil
    /// for a file that does not read, whose license forbids embedding, or whose outlines are CFF (it would have to go
    /// whole into every PDF).
    private func hostFont(_ file: ScorePDFFontFile) -> PDFFontEmbedding? {
        let key = "\(file.key)#\(file.faceIndex)"
        if let known = hostFiles[key] { return known }
        var embedding: PDFFontEmbedding?
        if let font = try? OpenTypeFont(file.data, faceIndex: file.faceIndex), font.isEmbeddable,
           !font.hasCFFOutlines
        {
            let number = faces.count + hostOrder.count + 1
            embedding = PDFFontEmbedding(
                font: font, baseName: font.postScriptName ?? "Font\(number)", resourceName: "F\(number)",
                symbolic: false,
            )
        }
        if let embedding { hostOrder.append(embedding) }
        hostFiles[key] = .some(embedding)
        return embedding
    }

    /// The graphics state that paints at `alpha` (0…255) — fills and strokes alike.
    func alphaState(_ alpha: UInt8) -> String {
        alphas.insert(alpha)
        return Self.stateName(alpha)
    }

    /// Embeds the fonts the pages used and returns the resources dictionary every page names.
    func write(into writer: PDFObjectWriter) throws -> String {
        var fonts: [String] = []
        for embedding in faces + hostOrder where !embedding.used.isEmpty {
            try fonts.append("/\(embedding.resourceName) \(embedding.embed(into: writer)) 0 R")
        }
        let states = alphas.sorted().map { alpha in
            let fraction = PDFPageWalker.number(Double(alpha) / 255)
            return "/\(Self.stateName(alpha)) << /Type /ExtGState /ca \(fraction) /CA \(fraction) >>"
        }
        return "<< /Font << \(fonts.joined(separator: " ")) >> /ExtGState << \(states.joined(separator: " ")) >> >>"
    }

    private static func stateName(_ alpha: UInt8) -> String {
        "GS\(alpha)"
    }
}
