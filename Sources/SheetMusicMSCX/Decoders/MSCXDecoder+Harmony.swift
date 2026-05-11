import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Harmony {
    /// Decode a `<Harmony>` element. Mirrors
    /// `TRead::read(Harmony*, ...)` in MuseScore's
    /// `engraving/rw/read410/tread.cpp` (around line 2970).
    /// Permissive — unknown children (`<degree>`, `<extension>`,
    /// `<function>`, `<harmonyVoiceLiteral>`, `<harmonyVoicing>`,
    /// `<harmonyDuration>`) are silently skipped.
    static func decode(_ node: XMLTreeNode) throws -> Harmony {
        let name = node.first("name")
            .map(StaffText.plainText(of:)) ?? ""
        let typeRaw = node.first("harmonyType")?.text ?? "0"
        let harmonyType = decodeHarmonyType(typeRaw)
        let rootTpc = decodeTpc(node.first("root")?.text)
        let bassTpc = decodeTpc(node.first("base")?.text)
        let rootCase = decodeNoteCase(node.first("rootCase")?.text)
        let bassCase = decodeNoteCase(node.first("baseCase")?.text)
        let leftParen = node.children.contains { $0.name == "leftParen" }
        let rightParen = node.children.contains { $0.name == "rightParen" }
        let play = decodePlay(node.first("play")?.text)
        let color = node.first("color").flatMap(StaffText.decodeColor(_:))
        let offset = node.first("offset")
            .map(StaffText.decodeOffset(_:)) ?? (0, 0)
        let properties = TextProperties.decode(node)
        let visible = (node.first("visible")?.text ?? "1") != "0"
        return Harmony(
            name: name,
            harmonyType: harmonyType,
            rootTpc: rootTpc,
            rootCase: rootCase,
            bassTpc: bassTpc,
            bassCase: bassCase,
            leftParen: leftParen,
            rightParen: rightParen,
            play: play,
            offsetX: offset.0,
            offsetY: offset.1,
            color: color,
            properties: properties,
            visible: visible,
        )
    }

    private static func decodeHarmonyType(_ raw: String) -> HarmonyType {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return .roman
        case "2": return .nashville
        default: return .standard
        }
    }

    private static func decodeNoteCase(_ raw: String?) -> NoteCase {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return .upper
        case "2": return .lower
        case "3": return .capitalize
        default: return .auto
        }
    }

    /// MuseScore writes `TPC_INVALID` (`-1`) when no root / bass is
    /// resolved. Normalise to `nil` so downstream code never does
    /// arithmetic on -1.
    private static func decodeTpc(_ raw: String?) -> Int? {
        guard let raw = raw?.trimmingCharacters(
            in: .whitespacesAndNewlines,
        ),
            let value = Int(raw)
        else { return nil }
        return value == -1 ? nil : value
    }

    /// `<play>1</play>` / `<play>true</play>` → true. Missing tag
    /// also defaults to true (matches MuseScore's `Harmony` ctor).
    private static func decodePlay(_ raw: String?) -> Bool {
        guard let raw = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return true }
        return raw == "1" || raw == "true"
    }
}
