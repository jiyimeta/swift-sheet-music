import Foundation

/// Two-axis alignment for a text element. Mirrors MuseScore's
/// `mu::engraving::Align` (`engraving/types/types.h`), which is
/// stored as a `(AlignH, AlignV)` pair and serialized in MSCX as
/// `"horizontal,vertical"` (e.g. `"center,bottom"`).
public struct TextAlign: Sendable, Equatable, Hashable {
    public enum Horizontal: String, Sendable, Equatable, Hashable {
        case left
        case center
        case right
    }

    /// MuseScore's `AlignV` is `{TOP, VCENTER, BOTTOM, BASELINE}`.
    /// Title-block layout only uses TOP / BOTTOM, but `baseline`
    /// is preserved so other text styles can round-trip later.
    public enum Vertical: String, Sendable, Equatable, Hashable {
        case top
        case center
        case bottom
        case baseline
    }

    public var horizontal: Horizontal
    public var vertical: Vertical

    public init(horizontal: Horizontal, vertical: Vertical) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    /// Parse the MSCX `"h,v"` form. Returns `nil` if either axis
    /// fails to parse — matches the permissive style of the rest
    /// of the decoder. Accepts MuseScore's `hcenter` / `vcenter`
    /// variants as aliases for `center`.
    public init?(mscxString raw: String) {
        let parts = raw.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let h = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
        let v = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        guard let hh = Horizontal.parse(h), let vv = Vertical.parse(v) else {
            return nil
        }
        self.init(horizontal: hh, vertical: vv)
    }

    /// MSCX serialization. `center` is emitted as `"center"` (not
    /// `"hcenter"` / `"vcenter"`) — MuseScore Studio 4 accepts both
    /// but writes the short form.
    public var mscxString: String {
        "\(horizontal.rawValue),\(vertical.rawValue)"
    }
}

extension TextAlign.Horizontal {
    fileprivate static func parse(_ s: String) -> Self? {
        switch s {
        case "left": return .left
        case "center", "hcenter": return .center
        case "right": return .right
        default: return nil
        }
    }
}

extension TextAlign.Vertical {
    fileprivate static func parse(_ s: String) -> Self? {
        switch s {
        case "top": return .top
        case "center", "vcenter": return .center
        case "bottom": return .bottom
        case "baseline": return .baseline
        default: return nil
        }
    }
}
