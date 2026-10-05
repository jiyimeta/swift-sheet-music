import SheetMusicBridgeCore
import SheetMusicFoundation

/// What every page of one PDF draws with, shared across the document: the five faces (each embedded once, and only if
/// a page used it) and a graphics state per alpha the pages paint in.
final class PDFResources {
    /// One per `Face`, at its raw value.
    private let faces: [PDFFontEmbedding]
    private var alphas: Set<UInt8> = [255]

    /// The bundled faces. Bravura for SMuFL; Edwin's four for text, picked by the text style as the Windows renderer
    /// picks them — semibold draws regular, and the platform UI face draws in Edwin, the face the table measures it in.
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
    }

    /// The face a font id draws in under `style` (`DrawCommand.TextStyleFlag` bits).
    func font(_ fontId: DrawProgram.FontID, style: UInt8) -> PDFFontEmbedding {
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

    /// The graphics state that paints at `alpha` (0…255) — fills and strokes alike.
    func alphaState(_ alpha: UInt8) -> String {
        alphas.insert(alpha)
        return Self.stateName(alpha)
    }

    /// Embeds the fonts the pages used and returns the resources dictionary every page names.
    func write(into writer: PDFObjectWriter) throws -> String {
        var fonts: [String] = []
        for embedding in faces where !embedding.used.isEmpty {
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
