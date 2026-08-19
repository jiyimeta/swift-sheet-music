import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Tracks `<glissando>` / `<slide>` start/stop events as the measure walker
/// crosses notes inside a single MusicXML `<part>`. MusicXML emits these
/// as paired events under `<notations>` — `type="start"` on the source note,
/// `type="stop"` on a later destination note — disambiguated by `number`
/// (defaulting to 1) and kind. We attach the resolved `Glissando` value
/// to the start chord's first `Note` only after the matching stop arrives,
/// so unmatched starts and unmatched stops both silently drop (permissive).
///
/// `<glissando>` maps to MuseScore's notated-pitch styles (`.chromatic`,
/// `.diatonic`, `.whiteKeys`, `.blackKeys`); `<slide>` maps to
/// `.portamento`. The `line-type` attribute (`wavy`, `solid`, `dashed`,
/// `dotted`) drives `VisualType` — only `wavy` becomes `.wavy`, anything
/// else is `.straight`.
struct MusicXMLGlideTracker {
    /// (kind, number) identity for matching start ↔ stop. Two glissandi
    /// with different `number` attributes may interleave without colliding.
    struct Key: Hashable {
        enum Kind: Hashable { case glissando, slide }
        let kind: Kind
        let number: Int
    }

    /// Where in the per-staff measure tree a glissando starts. Recorded
    /// at the moment the start `<note>` is processed; consumed when the
    /// matching stop arrives so the start chord's first note can be
    /// mutated in-place.
    struct StartLocation {
        let staffIndex: Int
        let measureIndex: Int
        /// Positional voice index inside the built `Measure.voices`
        /// array (resolved from MusicXML voice id via the staff
        /// builder at start time).
        let voiceIndex: Int
        /// Index of the chord (or other voice element) inside the
        /// voice's `elements` at start time.
        let elementIndex: Int
        let glissando: Glissando
    }

    /// Pending starts indexed by `(kind, number)`.
    private var pending: [Key: StartLocation] = [:]
    /// Resolved attachments accumulated for post-build mutation.
    private(set) var attachments: [StartLocation] = []

    /// Walk a single note's `<notations>` for glissando/slide events,
    /// updating pending starts and producing attachments.
    /// `chordElementIndex` is the index of the chord (or the last
    /// element appended in `.new(...)`) inside the destination voice.
    mutating func consume(
        noteNode: XMLTreeNode,
        staffIndex: Int,
        measureIndex: Int,
        voiceIndex: Int,
        chordElementIndex: Int,
    ) {
        guard let notations = noteNode.first("notations") else { return }
        for child in notations.children {
            guard let kind = kind(of: child.name) else { continue }
            let number = Int(child.attributes["number"] ?? "1") ?? 1
            let key = Key(kind: kind, number: number)
            switch child.attributes["type"] {
            case "start":
                pending[key] = StartLocation(
                    staffIndex: staffIndex,
                    measureIndex: measureIndex,
                    voiceIndex: voiceIndex,
                    elementIndex: chordElementIndex,
                    glissando: makeGlissando(kind: kind, node: child),
                )
            case "stop":
                if let start = pending.removeValue(forKey: key) {
                    attachments.append(start)
                }
            default:
                continue
            }
        }
    }

    private func kind(of elementName: String) -> Key.Kind? {
        switch elementName {
        case "glissando": .glissando
        case "slide": .slide
        default: nil
        }
    }

    /// Build a `Glissando` value from the start event. `<glissando>` is
    /// notated-pitch (defaults to `.chromatic`); `<slide>` is continuous
    /// pitch bend (`.portamento`). MusicXML's `line-type` drives the
    /// visual rendering — only `wavy` becomes `.wavy`. The element's
    /// text content (when non-empty) becomes the optional label.
    private func makeGlissando(kind: Key.Kind, node: XMLTreeNode) -> Glissando {
        let style: Glissando.Style = (kind == .slide) ? .portamento : .chromatic
        let visualType: Glissando.VisualType =
            (node.attributes["line-type"] == "wavy") ? .wavy : .straight
        let label = node.text
        return Glissando(
            style: style,
            visualType: visualType,
            text: label.isEmpty ? nil : label,
        )
    }
}
