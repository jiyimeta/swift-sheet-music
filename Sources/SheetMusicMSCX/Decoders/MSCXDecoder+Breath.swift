import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Breath {
    /// Decode a `<Breath>` element. Unknown `<subtype>` falls back to
    /// `.breathMark(.comma)` with a warning. Missing `<pause>` uses
    /// `Breath.defaultPause(for:)`.
    static func decodeMSCX(_ node: XMLTreeNode) -> Breath {
        let rawSubtype = node.first("subtype")?.text ?? ""
        let kind: Breath.Kind
        if let parsed = Breath.Kind.decode(mscxSubtype: rawSubtype) {
            kind = parsed
        } else {
            #if canImport(os)
                mscxDecoderLogger.warning(
                    """
                    unknown <Breath><subtype>: \
                    \(rawSubtype, privacy: .public) — falling back to \
                    breathMarkComma
                    """,
                )
            #endif
            kind = .breathMark(.comma)
        }
        let pause: Double? = node.first("pause").flatMap { Double($0.text) }
        var breath = Breath(kind: kind, pause: pause)
        breath.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return breath
    }
}
