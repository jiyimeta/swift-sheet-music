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
    private static let consumedVBoxChildren: Set = ["height", "Text"]

    /// Parse a `<VBox>` element. Permissive — unknown children are
    /// preserved. Default height is 0 if `<height>` is missing /
    /// malformed; layout will still allocate at least enough space
    /// for the contained text in that case.
    static func decode(vbox node: XMLTreeNode) -> ScoreFrame {
        var height: CGFloat = 0
        if let raw = node.first("height")?.text, let parsed = Double(raw) {
            height = CGFloat(parsed)
        }
        // `FrameText.decode` returns nil for empty text. `Text` must still be
        // consumed to avoid duplicating modeled text, so an empty `<Text>` is
        // a pre-existing loss that this score-block slice does not fix.
        let texts = node.all("Text").compactMap(FrameText.decode(_:))
        return ScoreFrame(
            heightSp: height,
            texts: texts,
            preservedMarkup: node.preservedMarkup(consuming: consumedVBoxChildren),
        )
    }
}

extension FrameText {
    static func decode(_ node: XMLTreeNode) -> FrameText? {
        let textNode = node.first("text")
        // Deliberately the element's own character data, run through the
        // string-level stripper below, rather than `plainText(of:)`. Reading
        // descendants would start admitting a title written entirely inside
        // `<b>`, which this decoder has always dropped — a real improvement,
        // but a behaviour change that belongs in its own commit with its own
        // test, not folded into carrying the markup.
        let stripped = stripInlineMarkup(textNode?.text ?? "")
        guard !stripped.isEmpty else { return nil }
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

/// Drop the inline `<b>` / `<i>` / `<font …>` tags MuseScore emits
/// inside `<text>` so callers see plain text. A future revision can
/// expose a structured representation if styling matters; for now
/// the renderer treats title-block text as plain.
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
