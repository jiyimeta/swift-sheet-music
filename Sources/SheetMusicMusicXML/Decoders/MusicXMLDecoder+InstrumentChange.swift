import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// MusicXML has no single equivalent of `<InstrumentChange>`. Synthesize
/// one wherever the `<instrument id>` a note references changes, and
/// honor MusicXML 4.0's explicit `<sound><instrument-change>` when the
/// exporter wrote one. Best-effort by design: verified against a
/// MusicXML export produced from a MuseScore score, not against the
/// `.mscx` fixture it was exported from — the two formats disagree on
/// how the change is spelled and only the MusicXML side is under test
/// here.
enum MusicXMLInstrumentChangeDecoder {
    /// One entry per `<measure>` in the part, in document order. Nearly
    /// every entry is empty; a non-empty entry holds the single
    /// synthesized `.instrumentChange` for that measure. Always placed at
    /// `MeasurePosition.start` — this importer has no per-note tick
    /// cursor to place it more precisely (`MusicXMLMeasureWalker` treats
    /// `<backup>`/`<forward>` as no-ops and relies on document order),
    /// so a mid-measure change collapses to the downbeat, matching how
    /// rehearsal marks are already positioned.
    static func decode(
        partNode: XMLTreeNode,
        instrumentByID: [String: Instrument],
        seedInstrumentID: String?,
    ) -> [[PositionedSystemElement]] {
        var previousID = seedInstrumentID
        var perMeasure: [[PositionedSystemElement]] = []
        for measureNode in partNode.all("measure") {
            let (elements, nextID) = decodeOne(
                measureNode: measureNode,
                instrumentByID: instrumentByID,
                previousID: previousID,
            )
            previousID = nextID
            perMeasure.append(elements)
        }
        return perMeasure
    }

    /// Decide whether this measure carries an instrument change, and
    /// return the id now in effect (whether or not a change was
    /// emitted) so the caller can thread it into the next measure.
    private static func decodeOne(
        measureNode: XMLTreeNode,
        instrumentByID: [String: Instrument],
        previousID: String?,
    ) -> (elements: [PositionedSystemElement], nextID: String?) {
        var lastNoteID = previousID
        for note in measureNode.all("note") {
            if let id = note.first("instrument")?.attributes["id"] {
                lastNoteID = id
            }
        }

        // Prefer the explicit MusicXML 4.0 signal when it resolves; only
        // fall back to the per-note transition otherwise. This fixture
        // carries both signals for the same change, so without this
        // priority the change would be emitted twice.
        let explicitID = explicitInstrumentChangeID(in: measureNode)
        let candidateID: String? = if let explicitID, instrumentByID[explicitID] != nil {
            explicitID
        } else if lastNoteID != previousID {
            lastNoteID
        } else {
            nil
        }

        guard let targetID = candidateID, targetID != previousID else {
            return ([], lastNoteID)
        }

        // `targetID` may not resolve — a malformed export can reference an
        // id no `<score-instrument>` declares. `InstrumentChange.instrument`
        // is `Instrument?` precisely for this: still engrave the
        // instruction text (the reader should see it even though the file
        // is malformed), but contribute no `instrumentTimeline` point —
        // `nil` there is read as "no change" by
        // `Score.instrumentTimeline(forPart:)`, so playback/channel
        // allocation stay unaffected. Falls back to the bare id string as
        // a last resort so `text` is never empty.
        let instrument = instrumentByID[targetID]
        let text = directionWordsText(in: measureNode)
            ?? instrument?.longName
            ?? instrument?.trackName
            ?? targetID
        let change = InstrumentChange(text: text, instrument: instrument)
        let element = PositionedSystemElement(
            position: .start,
            element: .instrumentChange(change),
        )
        return ([element], targetID)
    }

    /// MusicXML 4.0's explicit change signal: `<sound><instrument-change
    /// id="…">` as a direct child of `<measure>`.
    private static func explicitInstrumentChangeID(in measureNode: XMLTreeNode) -> String? {
        for sound in measureNode.all("sound") {
            if let id = sound.first("instrument-change")?.attributes["id"] {
                return id
            }
        }
        return nil
    }

    /// The engraved instruction text arrives as a sibling
    /// `<direction><direction-type><words>`, not nested inside
    /// `<instrument-change>`. Heuristic match: the first non-empty
    /// `<words>` text anywhere in the same measure — good enough since
    /// MusicXML carries no explicit link between the two elements.
    private static func directionWordsText(in measureNode: XMLTreeNode) -> String? {
        for direction in measureNode.all("direction") {
            guard let directionType = direction.first("direction-type") else { continue }
            for words in directionType.all("words") where !words.text.isEmpty {
                return words.text
            }
        }
        return nil
    }
}
