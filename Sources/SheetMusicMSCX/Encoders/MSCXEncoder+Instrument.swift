import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Instrument {
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        if let longName {
            children.append(XMLTreeNode(name: "longName", text: longName))
        }
        if let shortName {
            children.append(XMLTreeNode(name: "shortName", text: shortName))
        }
        if let trackName {
            children.append(XMLTreeNode(name: "trackName", text: trackName))
        }
        if let v = minPitchPlayable {
            children.append(XMLTreeNode(name: "minPitchP", text: String(v)))
        }
        if let v = maxPitchPlayable {
            children.append(XMLTreeNode(name: "maxPitchP", text: String(v)))
        }
        if let v = minPitchAmateur {
            children.append(XMLTreeNode(name: "minPitchA", text: String(v)))
        }
        if let v = maxPitchAmateur {
            children.append(XMLTreeNode(name: "maxPitchA", text: String(v)))
        }
        // MuseScore writes the transposition pair right after the pitch ranges and before
        // `<instrumentId>` / `<Channel>`, and omits both at the concert-pitch default of 0 — so a
        // non-transposing instrument keeps its existing byte shape. Both are written whenever
        // either is set: an octave transposition is `diatonic -7 / chromatic -12`, and dropping the
        // zero half of a pair would make it unreadable.
        if isTransposing {
            children.append(XMLTreeNode(
                name: "transposeDiatonic", text: String(transposeDiatonic),
            ))
            children.append(XMLTreeNode(
                name: "transposeChromatic", text: String(transposeChromatic),
            ))
        }
        appendDrumset(into: &children)
        // Match MuseScore's writer: `<StringData>` follows playback properties
        // and precedes `<MidiAction>` / `<Articulation>` / `<Channel>`
        // (`rw/write/twrite.cpp:2025`). It previously rode in preserved markup
        // at the end of `<Instrument>`; this moves rather than loses it, and the
        // preservation gate compares parent/child counts rather than positions.
        if let stringData {
            children.append(stringData.encode(options: options))
        }
        for art in articulations {
            children.append(art.encode())
        }
        for chan in channels {
            children.append(chan.encode(options: options))
        }
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(
            name: "Instrument",
            attributes: ["id": id],
            children: children,
        )
    }

    /// Append the percussion-kit block: the `<instrumentId>` / `<useDrumset>` marker pair and one
    /// `<Drum>` per mapped pitch.
    private func appendDrumset(into children: inout [XMLTreeNode]) {
        if useDrumset {
            // MuseScore Studio looks up the drumset template by the
            // canonical `<instrumentId>` (Sound ID) — without it,
            // every per-pitch `<Drum>` override is ignored and all
            // drums collapse onto the default line. The `id`
            // attribute alone (e.g. "drumset") is not enough.
            children.append(XMLTreeNode(
                name: "instrumentId", text: "drum.group.set",
            ))
            children.append(XMLTreeNode(name: "useDrumset", text: "1"))
        }
        // MuseScore Studio refuses to apply per-pitch line positions
        // when a `<Drum>` entry lacks `<head>` / `<voice>` / `<stem>` /
        // `<name>` — every drum then renders on the same default line.
        // `DrumsetEntry` carries all four, filled from `GMDrumset` for
        // an authored kit and from the file for a decoded one. Element
        // order matches MuseScore's own writer: head → line → voice →
        // name → stem → shortcut.
        for pitch in drumset.keys.sorted() {
            guard let entry = drumset[pitch] else { continue }
            var drumChildren: [XMLTreeNode] = [
                XMLTreeNode(name: "head", text: entry.head),
                XMLTreeNode(name: "line", text: String(entry.line)),
                XMLTreeNode(name: "voice", text: String(entry.voiceIndex)),
                XMLTreeNode(name: "name", text: entry.name),
                XMLTreeNode(name: "stem", text: String(entry.stem)),
            ]
            if let shortcut = entry.shortcut {
                drumChildren.append(XMLTreeNode(name: "shortcut", text: shortcut))
            }
            children.append(XMLTreeNode(
                name: "Drum",
                attributes: ["pitch": String(pitch)],
                children: drumChildren,
            ))
        }
    }
}
