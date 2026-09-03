import SheetMusicFoundation

/// Source markup this library does not model, kept verbatim so that
/// read → write does not delete it.
///
/// **Inert.** No layout, playback, MIDI, or editing pass reads this.
/// It exists solely so `MSCXEncoder` can put back what `MSCXParser`
/// did not understand. Before it existed, an element outside the
/// model was dropped on read and therefore erased on the next save.
///
/// **Fidelity, not semantics.** Preserved markup describes the file
/// as it was read. Editing the score can leave it stale — a preserved
/// `<Excerpt>` still describes the part layout of the *original*
/// score. Keeping it is judged better than deleting it, but a host
/// that would rather drop it can call
/// `Score.strippingPreservedMarkup()`, or encode with
/// `MSCXEncoderOptions.emitPreservedMarkup` set to `false`.
///
/// C++: no counterpart. MuseScore models every element it writes.
public struct PreservedXML: Sendable, Equatable {
    public let name: String
    public let attributes: [String: String]
    public let text: String
    public let children: [PreservedXML]

    public init(
        name: String,
        attributes: [String: String] = [:],
        text: String = "",
        children: [PreservedXML] = [],
    ) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
    }
}
