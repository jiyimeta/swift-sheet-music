#if canImport(CoreGraphics)
    import CoreGraphics
#elseif !os(WASI)
    // Android and Linux take `CGFloat` / `CGPoint` from
    // swift-corelibs-foundation, and only the umbrella carries them —
    // `SheetMusicFoundation` resolves to `FoundationEssentials` on both
    // platforms, which has neither. Same gate, and the same reason, as
    // `SheetMusicCore`'s own `ScoreFrame.swift`: the Android JNI bridge
    // depends on those exact types rather than a structurally identical
    // local copy.
    //
    // WASI needs no branch: `SheetMusicCore` declares its own CG types
    // under `os(WASI)` and this file imports that module, so the umbrella
    // never reaches the wasm binary.
    // swiftlint:disable:next no_foundation_umbrella
    import Foundation
#endif
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ScoreFrame {
    private static let consumedVBoxChildren: Set = ["height", "Text", "boxAutoSize", "Image"]

    /// Parse a `<VBox>` element. Permissive — unknown children are
    /// preserved. Default height is 0 if `<height>` is missing /
    /// malformed; layout will still allocate at least enough space
    /// for the contained text in that case.
    static func decode(vbox node: XMLTreeNode) -> ScoreFrame {
        let box = BoxChildren(node, consuming: consumedVBoxChildren)
        // `FrameText.decode` returns nil only for a `<Text>` with neither text nor markup; `Text` is consumed either
        // way, so such an empty block is the one thing not written back.
        let texts = node.all("Text").compactMap(FrameText.decode(_:))
        return ScoreFrame(
            heightSp: box.number("height") ?? 0,
            texts: texts,
            preservedMarkup: box.preservedMarkup,
            topGapSp: box.topGapSp,
            bottomGapSp: box.bottomGapSp,
            autoSize: node.first("boxAutoSize")?.text.map { $0 == "1" || $0 == "true" },
            images: node.all("Image").map(FrameImage.decode(_:)),
        )
    }
}

extension FrameText {
    static func decode(_ node: XMLTreeNode) -> FrameText? {
        let textNode = node.first("text")
        // A `<text>` with child elements reads as its plain projection (`StaffText.plainText(of:)`), untouched:
        // `X<br/>arr. Y` keeps its line break, a line written entirely inside `<b>` keeps its characters, and neither a
        // trim nor the stripper runs — a trim would drop a leading or trailing `<br/>` line that `richText` keeps (the
        // title layout pairs text lines with rich lines by index), and the stripper would eat a decoded `&lt;`. A
        // `<text>` without children keeps the legacy path: `stripInlineMarkup` removes tags that arrive as characters
        // — MuseScore 2's escaped `&lt;font …/&gt;` — and trims, exactly as before.
        let stripped = if let textNode, !textNode.children.isEmpty {
            StaffText.plainText(of: textNode)
        } else {
            stripInlineMarkup(textNode?.text ?? "")
        }
        // A line whose markup holds only a symbol projects to "" but is still a line: dropping it lost it from the
        // saved file.
        guard !stripped.isEmpty || textNode?.children.isEmpty == false else { return nil }
        let style = (node.first("style")?.text)
            .flatMap(decodeStyle(_:)) ?? .other
        var offsetMm: CGPoint?
        if let off = node.first("offset"),
           let xs = off.attributes["x"], let ys = off.attributes["y"],
           let x = Double(xs), let y = Double(ys)
        {
            offsetMm = CGPoint(x: x, y: y)
        }
        var fontSize: Double?
        if let raw = node.first("size")?.text, let v = Double(raw) {
            fontSize = v
        }
        let align = (node.first("align")?.text)
            .flatMap(TextAlign.init(mscxString:))
        return FrameText(
            style: style, text: stripped,
            offsetMm: offsetMm, fontSize: fontSize, align: align,
            preservedTextMarkup: textNode.flatMap {
                StaffText.preservedTextMarkup(of: $0, derivedText: stripped)
            },
        )
    }
}

/// Drop tags that arrive as CHARACTERS inside a childless `<text>` — MuseScore 2 escaped its `<font …/>` as
/// `&lt;font …/&gt;` — and trim, so that legacy shape reads as plain text. Markup that arrives as elements never comes
/// here: `FrameText.decode` reads it in source order, and it is drawn from `FrameText.richText`.
private func stripInlineMarkup(_ s: String) -> String {
    var result = ""
    var inTag = false
    for char in s {
        if char == "<" { inTag = true; continue }
        if char == ">" { inTag = false; continue }
        if !inTag { result.append(char) }
    }
    return result.trimmingWhitespaceAndNewlines()
}

/// MuseScore writes the `<style>` value with the engraving enum's
/// canonical name, which is lowercase since MuseScore 4 (`title`,
/// `subtitle`, `composer`, `poet`). MuseScore 3 used the Pascal-case
/// form (`Title`, …), and our own encoder still emits Pascal-case for
/// round-trip compatibility — so the decoder accepts both. The
/// historical tag `poet` is the engraving-enum name for the role our
/// public API calls `.lyricist` (see `engraving/types/types.h`).
private func decodeStyle(_ raw: String) -> FrameText.Style? {
    switch raw.lowercased() {
    case "title": return .title
    case "subtitle": return .subtitle
    case "composer": return .composer
    case "lyricist", "poet": return .lyricist
    default: return nil
    }
}
