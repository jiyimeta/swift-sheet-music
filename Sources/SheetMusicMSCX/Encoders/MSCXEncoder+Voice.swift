import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    /// Build the `<voice>` element. Phase 1 supports the element
    /// kinds present in `midi01.mscx`: chords (with rests as
    /// notes-empty chords), key/time/clef changes. Other cases
    /// (Tempo, Dynamic, Spanner, Harmony, …) are added in follow-up
    /// specs and trap here with a clear message until then.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        for element in elements {
            switch element {
            case let .chord(chord):
                children.append(chord.notes.isEmpty
                    ? chord.encodeAsRest()
                    : chord.encodeAsChord())
            case let .keySignature(key):
                children.append(key.encode())
            case let .timeSignature(time):
                children.append(time.encode())
            case let .clef(clef):
                children.append(clef.encode())
            case .barLine, .tempo, .dynamic, .spanner,
                 .measureRepeat, .fermata, .staffText, .harmony,
                 .rehearsalMark, .locationShift:
                fatalError(
                    "VoiceElement \(element) not yet supported by " +
                        "MSCXEncoder Phase 1 — see " +
                        "docs/superpowers/specs/2026-05-07-mscx-export-design.md"
                )
            }
        }
        // Tuplets are not exercised by midi01; encoding them is a
        // Phase-2 concern (requires <Tuplet> + <endTuplet> markers
        // interleaved with the elements).
        return XMLTreeNode(name: "voice", children: children)
    }
}
