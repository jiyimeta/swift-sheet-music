import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension TextProperties {
    /// Read MuseScore's per-element `<face>`, `<size>`, `<bold>`,
    /// `<italic>`, `<underline>`, `<strike>`, `<frameType>`,
    /// `<framePadding>` children. Permissive — any missing field is
    /// left `nil` so the renderer falls back to the
    /// `TextStyleType` default.
    ///
    /// MuseScore writes `<bold>1</bold>` etc. only when the value
    /// diverges from the style; an absent flag thus means "inherit".
    /// We honour that exactly.
    static func decode(_ node: XMLTreeNode) -> TextProperties {
        var props = TextProperties()
        if let face = node.first("face")?.text, !face.isEmpty {
            props.face = face
        }
        if let raw = node.first("size")?.text, let v = Double(raw) {
            props.size = v
        }
        // Bold / italic / underline / strike are independent flags;
        // an absent element means "no opinion" — we collect the
        // ones that were set into a partial bitmask, but only emit
        // a non-nil `style` if at least one was specified.
        var styleSet = FontStyleSet()
        var anyStyleFlag = false
        if let v = node.firstBoolFlag("bold") {
            anyStyleFlag = true
            if v { styleSet.insert(.bold) }
        }
        if let v = node.firstBoolFlag("italic") {
            anyStyleFlag = true
            if v { styleSet.insert(.italic) }
        }
        if let v = node.firstBoolFlag("underline") {
            anyStyleFlag = true
            if v { styleSet.insert(.underline) }
        }
        if let v = node.firstBoolFlag("strike") {
            anyStyleFlag = true
            if v { styleSet.insert(.strike) }
        }
        if anyStyleFlag {
            props.style = styleSet
        }
        if let raw = node.first("frameType")?.text, let v = Int(raw) {
            props.frameType = decodeFrame(v)
        }
        if let raw = node.first("framePadding")?.text,
           let v = Double(raw)
        {
            props.framePadding = v
        }
        return props
    }
}

/// Resolve `<frameType>0|1|2</frameType>` to `TextFrameType`.
/// Mirrors MuseScore's `FrameType` enum order
/// (`engraving/types/types.h`):  SQUARE=0, CIRCLE=1, NO_FRAME=2.
func decodeFrame(_ raw: Int) -> TextFrameType {
    switch raw {
    case 0: .rectangle
    case 1: .circle
    case 2: .none
    default: .none
    }
}

extension XMLTreeNode {
    /// Read a `0`/`1` boolean child. Returns `nil` if the child is
    /// absent so callers can distinguish "not specified" from
    /// "explicitly false".
    fileprivate func firstBoolFlag(_ name: String) -> Bool? {
        guard let raw = first(name)?.text, let n = Int(raw) else {
            return nil
        }
        return n != 0
    }
}
