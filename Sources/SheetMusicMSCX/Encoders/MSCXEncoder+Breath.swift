import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Breath.Kind {
    /// MSCX `<subtype>` → `Breath.Kind`. Returns `nil` for unknown
    /// subtypes — decoder falls back to `.breathMark(.comma)` with a
    /// warning.
    static func decode(mscxSubtype: String) -> Breath.Kind? {
        switch mscxSubtype {
        case "breathMarkComma": return .breathMark(.comma)
        case "breathMarkTick": return .breathMark(.tick)
        case "breathMarkUpbow": return .breathMark(.upbow)
        case "breathMarkSalzedo": return .breathMark(.salzedo)
        case "caesura": return .caesura(.normal)
        case "caesuraShort": return .caesura(.short)
        case "caesuraThick": return .caesura(.thick)
        case "caesuraCurved": return .caesura(.curved)
        default: return nil
        }
    }

    /// MSCX `<subtype>` text for round-trip.
    var mscxSubtype: String {
        switch self {
        case .breathMark(.comma): return "breathMarkComma"
        case .breathMark(.tick): return "breathMarkTick"
        case .breathMark(.upbow): return "breathMarkUpbow"
        case .breathMark(.salzedo): return "breathMarkSalzedo"
        case .caesura(.normal): return "caesura"
        case .caesura(.short): return "caesuraShort"
        case .caesura(.thick): return "caesuraThick"
        case .caesura(.curved): return "caesuraCurved"
        }
    }
}

extension Breath {
    /// Build a `<Breath>` element. `<pause>` is omitted when it matches
    /// the kind's default — same "omit when default" convention used by
    /// `Fermata.encode()` for `<timeStretch>`.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: kind.mscxSubtype),
        ]
        let defaultPause = Breath.defaultPause(for: kind)
        if pause != defaultPause {
            children.append(XMLTreeNode(
                name: "pause",
                text: formatPause(pause),
            ))
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        return XMLTreeNode(name: "Breath", children: children)
    }

    /// Match MuseScore's pause formatting: whole numbers without a
    /// trailing `.0`, fractional values verbatim. Mirrors
    /// `Fermata.formatStretch`.
    private func formatPause(_ value: Double) -> String {
        if value == value.rounded() {
            return String(Int(value))
        }
        return String(value)
    }
}
