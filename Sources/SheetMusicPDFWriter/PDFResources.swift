import SheetMusicBridgeCore
import SheetMusicFoundation
import SheetMusicLayout

/// What every page of one PDF draws with, shared across the document: the faces (each embedded once, and only if a
/// page used it) and a graphics state per alpha the pages paint in.
final class PDFResources {
    /// One per `Face`, at its raw value.
    private let faces: [PDFFontEmbedding]
    private let systemFile: @Sendable (FontWeight, Bool) -> Data?
    /// The platform UI face at each weight and slant asked for so far, in the order first asked; nil where it has no
    /// file the PDF may embed.
    private var system: [SystemStyle: PDFFontEmbedding?] = [:]
    private var systemOrder: [PDFFontEmbedding] = []
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

    /// The UI face for `style`, read the first time a page asks for it. Named after its PostScript name, and given the
    /// resource names after the bundled faces' (`F6`, …) in the order the pages first use them.
    private func systemFace(_ style: SystemStyle) -> PDFFontEmbedding? {
        if let known = system[style] { return known }
        var embedding: PDFFontEmbedding?
        if let data = systemFile(style.weight, style.isItalic) {
            // Two styles the host resolves to one file share its embedding.
            if let same = systemOrder.first(where: { $0.font.data == data }) {
                embedding = same
            } else if let font = try? OpenTypeFont(data), font.isEmbeddable {
                let number = faces.count + systemOrder.count + 1
                let added = PDFFontEmbedding(
                    font: font, baseName: font.postScriptName ?? "SystemFace\(number)", resourceName: "F\(number)",
                    symbolic: false,
                )
                systemOrder.append(added)
                embedding = added
            }
        }
        system[style] = .some(embedding)
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
        for embedding in faces + systemOrder where !embedding.used.isEmpty {
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
