import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Harmony {
    /// Build a `<Harmony>` element. Mirrors `Harmony.decode(_:)`:
    /// `<name>`, `<harmonyType>` (0/1/2), `<root>` / `<base>` (TPC,
    /// omitted when nil), `<rootCase>` / `<baseCase>` (omitted when
    /// `.auto`), self-closing `<leftParen/>` / `<rightParen/>` flags,
    /// `<play>` (only when false), `<color>`, `<offset>`, and the
    /// `TextProperties` block.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "name", text: name),
            XMLTreeNode(
                name: "harmonyType", text: encodeHarmonyType(harmonyType),
            ),
        ]
        if let rootTpc {
            children.append(XMLTreeNode(name: "root", text: String(rootTpc)))
        }
        if let bassTpc {
            children.append(XMLTreeNode(name: "base", text: String(bassTpc)))
        }
        if rootCase != .auto {
            children.append(XMLTreeNode(
                name: "rootCase", text: encodeNoteCase(rootCase),
            ))
        }
        if bassCase != .auto {
            children.append(XMLTreeNode(
                name: "baseCase", text: encodeNoteCase(bassCase),
            ))
        }
        if leftParen {
            children.append(XMLTreeNode(name: "leftParen"))
        }
        if rightParen {
            children.append(XMLTreeNode(name: "rightParen"))
        }
        if !play {
            children.append(XMLTreeNode(name: "play", text: "0"))
        }
        if let color {
            children.append(XMLTreeNode(
                name: "color",
                attributes: [
                    "r": String(color.red),
                    "g": String(color.green),
                    "b": String(color.blue),
                    "a": String(color.alpha),
                ],
            ))
        }
        if offsetX != 0 || offsetY != 0 {
            children.append(XMLTreeNode(
                name: "offset",
                attributes: [
                    "x": formatDouble(offsetX),
                    "y": formatDouble(offsetY),
                ],
            ))
        }
        if !visible {
            children.append(XMLTreeNode(name: "visible", text: "0"))
        }
        properties.appendXML(to: &children)
        return XMLTreeNode(name: "Harmony", children: children)
    }
}

private func encodeHarmonyType(_ type: HarmonyType) -> String {
    switch type {
    case .standard: "0"
    case .roman: "1"
    case .nashville: "2"
    }
}

private func encodeNoteCase(_ noteCase: NoteCase) -> String {
    switch noteCase {
    case .auto: "0"
    case .upper: "1"
    case .lower: "2"
    case .capitalize: "3"
    }
}
