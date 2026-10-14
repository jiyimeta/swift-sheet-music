import SheetMusicFoundation

extension Marker.Kind {
    /// MuseScore's `<markerType>` name for this kind (`TConv::toXml(MarkerType)`, `engraving/types/typesconv.cpp:
    /// 3097-3108`) — not the raw value: MuseScore's Coda is `codab` and its To Coda `coda`. The kinds MuseScore has no
    /// type for are written as its Custom type, `user`.
    package var mscxName: String {
        switch self {
        case .segno: "segno"
        case .varsegno: "varsegno"
        case .coda: "codab"
        case .varcoda: "varcoda"
        case .codetta: "codetta"
        case .fine: "fine"
        case .toCoda: "coda"
        case .toCodaSym: "codasym"
        case .daCoda: "dacoda"
        case .daDoubleCoda: "dadblcoda"
        case .user, .daCapo, .dalSegno, .other: "user"
        }
    }

    /// The kind MuseScore reads a `<markerType>` name as (`TConv::fromXml(MarkerType)`, `typesconv.cpp:3126-3143`,
    /// which also takes MuseScore 1's `Repeat` for a To Coda) — and, in a file older than format 4.60, the name a
    /// `<label>` carries (`rw/read410/tread.cpp:1761-1776`). `nil` for any other name; MuseScore reads those as USER.
    package init?(mscxName name: String) {
        switch name {
        case "segno": self = .segno
        case "varsegno": self = .varsegno
        case "codab": self = .coda
        case "varcoda": self = .varcoda
        case "codetta": self = .codetta
        case "fine": self = .fine
        case "coda", "Repeat": self = .toCoda
        case "codasym": self = .toCodaSym
        case "dacoda": self = .daCoda
        case "dadblcoda": self = .daDoubleCoda
        case "user": self = .user
        default: return nil
        }
    }
}
