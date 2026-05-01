import Foundation
import SheetMusicXMLTools

/// Maps `<note><instrument id="X"/></note>` references to the General MIDI
/// percussion pitch declared by the part's `<score-part>` block.
///
/// MusicXML stores percussion mappings in the score header:
/// ```xml
/// <score-part id="P6">
///   <score-instrument id="P6-I36"><instrument-name>Bass Drum 1</instrument-name></score-instrument>
///   <midi-instrument id="P6-I36">
///     <midi-channel>10</midi-channel>
///     <midi-unpitched>36</midi-unpitched>   <!-- 1-128, MIDI pitch = N - 1 -->
///   </midi-instrument>
///   ...
/// </score-part>
/// ```
/// Each `<note><unpitched>…</unpitched><instrument id="P6-I36"/></note>` then
/// looks up its actual MIDI drum pitch through this table. Mirrors MuseScore's
/// `importmusicxmlpass1.cpp:2614` which subtracts 1 from the value.
struct MusicXMLDrumTable: Equatable {
    /// `instrumentId` (e.g. "P6-I36") → MIDI pitch (0-127).
    private(set) var pitchByInstrumentId: [String: Int] = [:]
    /// True if any `<midi-unpitched>` was present, OR if any `<midi-channel>`
    /// equals 10. Either signals that the part is a drum kit and should be
    /// routed to the GM percussion channel.
    private(set) var isDrumset = false

    /// Build the table for one `<score-part>` element.
    static func build(scorePart: XMLTreeNode) -> MusicXMLDrumTable {
        var table = MusicXMLDrumTable()
        for midiInstr in scorePart.all("midi-instrument") {
            let id = midiInstr.attributes["id"] ?? ""
            if let unpitchedText = midiInstr.first("midi-unpitched")?.text,
               let raw = Int(unpitchedText), raw >= 1, raw <= 128
            {
                // MusicXML's 1-128 range → 0-127 MIDI numbering.
                table.pitchByInstrumentId[id] = raw - 1
                table.isDrumset = true
            }
            if let chText = midiInstr.first("midi-channel")?.text,
               let ch = Int(chText), ch == 10
            {
                table.isDrumset = true
            }
        }
        return table
    }
}
