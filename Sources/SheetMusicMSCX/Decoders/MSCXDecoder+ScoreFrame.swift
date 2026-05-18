#if canImport(CoreGraphics)
    import CoreGraphics
#else
    // On non-Apple platforms (Android, Linux), swift-corelibs-foundation
    // provides CGFloat / CGPoint via Foundation.
#endif
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension ScoreFrame {
    /// Parse a `<VBox>` element. Permissive — unknown children are
    /// ignored. Default height is 0 if `<height>` is missing /
    /// malformed; layout will still allocate at least enough space
    /// for the contained text in that case.
    static func decode(vbox node: XMLTreeNode) -> ScoreFrame {
        var height: CGFloat = 0
        if let raw = node.first("height")?.text, let parsed = Double(raw) {
            height = CGFloat(parsed)
        }
        let texts = node.all("Text").compactMap(FrameText.decode(_:))
        return ScoreFrame(heightSp: height, texts: texts)
    }
}

extension FrameText {
    static func decode(_ node: XMLTreeNode) -> FrameText? {
        let raw = node.first("text")?.text ?? ""
        let stripped = stripInlineMarkup(raw)
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
        )
    }
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
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
}
