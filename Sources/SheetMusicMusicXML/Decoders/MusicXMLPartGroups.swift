import SheetMusicXMLTools

/// The `<part-group>`s of a `<part-list>` as far as MuseScore's implicit brace needs them (`partGroup`,
/// `partGroupStart`, `partGroupStop`, `P1:2284-2390`). The groups' own brackets are not decoded.
struct MusicXMLPartGroups: Sendable, Equatable {
    /// One closed group: its first part (an index into the list's `<score-part>`s), how many parts it spans, its
    /// bracket column (the 0-based `number`) and whether its symbol makes a bracket (not `none` and not empty).
    struct Group: Sendable, Equatable {
        let start: Int
        let span: Int
        let column: Int
        let makesBracket: Bool
    }

    private(set) var groups: [Group] = []

    init(partList: XMLTreeNode) {
        var open: [Int: (start: Int, column: Int, makesBracket: Bool)] = [:]
        var parts = 0
        for child in partList.children {
            if child.name == "score-part" {
                parts += 1
                continue
            }
            guard child.name == "part-group" else { continue }
            let raw = Int(child.attributes["number"] ?? "") ?? 0
            let number = raw > 0 ? raw - 1 : raw
            switch child.attributes["type"] {
            case "start":
                // A number already open is ignored; so is a symbol MuseScore does not know (`P1:2288-2309`).
                guard open[number] == nil, let makesBracket = Self.makesBracket(symbol: Self.symbol(of: child))
                else { continue }
                open[number] = (parts, number, makesBracket)
            case "stop":
                guard let begun = open.removeValue(forKey: number) else { continue }
                groups.append(Group(
                    start: begun.start, span: parts - begun.start, column: begun.column,
                    makesBracket: begun.makesBracket,
                ))
            default:
                continue
            }
        }
    }

    /// The column of the brace MuseScore adds to a part of `staffCount` staves, or `nil` for none (`P1:1483-1499`):
    /// every multi-staff part gets one unless a group of that part alone draws a bracket, in the column after the
    /// highest one the groups starting at the part use (`bracketLevels + 1`, which is 1 when there are none).
    func impliedBraceColumn(partIndex: Int, staffCount: Int) -> Int? {
        guard staffCount > 1 else { return nil }
        let bracketing = groups.filter { $0.start == partIndex && $0.span > 0 && $0.makesBracket }
        guard !bracketing.contains(where: { $0.span == 1 }) else { return nil }
        return (bracketing.map(\.column).max() ?? 0) + 1
    }

    /// The group's symbol: `<group-symbol>`, or — as MuseScore reads it — a `<group-abbreviation>` after it.
    private static func symbol(of group: XMLTreeNode) -> String {
        var symbol = ""
        for child in group.children where child.name == "group-symbol" || child.name == "group-abbreviation" {
            symbol = child.text
        }
        return symbol
    }

    /// Whether `symbol` makes a bracket; `nil` for a symbol MuseScore does not support, which makes no group.
    private static func makesBracket(symbol: String) -> Bool? {
        switch symbol {
        case "", "none": false
        case "brace", "bracket", "line", "square": true
        default: nil
        }
    }
}
