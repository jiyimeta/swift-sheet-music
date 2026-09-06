import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension StringData {
    private static let consumedChildren: Set = ["frets", "string"]

    /// `<StringData>` or the legacy `<Tablature>` child of `<Instrument>`, or nil.
    ///
    /// The LAST of the two spellings wins, because MuseScore's reader dispatches
    /// them from one branch and each occurrence overwrites the last
    /// (`rw/read460/tread.cpp:1043`: `tag == "Tablature" || tag == "StringData"`,
    /// then `item->setStringData(sd)`). No file MuseScore writes carries both, so
    /// this only decides a hand-edited one — but deciding it the way upstream
    /// does is free.
    ///
    /// Normalizing the spelling on write is deliberate — MuseScore's own writer
    /// only ever emits `<StringData>` (`rw/write/twrite.cpp:3187`). It does mean
    /// a real MuseScore 2 score turns `Instrument/Tablature` into
    /// `Instrument/StringData`, which the preservation gate counts as a lost
    /// pair. No committed fixture spells it that way, so the gate is green; the
    /// opt-in corpus sweep over MS2 scores would report it, and the answer there
    /// is an `MSCXPreservation.allowedLosses` entry naming this decision — not a
    /// change to the encoder.
    static func decode(inInstrument node: XMLTreeNode) -> StringData? {
        node.children
            .last { $0.name == "StringData" || $0.name == "Tablature" }
            .map(decode)
    }

    /// Decode one `<StringData>` / `<Tablature>` element.
    ///
    /// Nothing throws, and nothing is dropped: a tuning is cosmetic under the
    /// parser policy, so an unreadable value falls back silently.
    ///
    /// **An unreadable `<string>` becomes pitch 0 rather than disappearing**,
    /// because the list is positional — `Note.string` is an INDEX into it, so
    /// skipping one entry would silently renumber every string after it.
    /// MuseScore reaches the same place from the other direction:
    /// `rw/read460/tread.cpp:4203-4208` pushes the entry unconditionally and
    /// `XmlReader::readInt()` yields 0 for text `strtol` cannot consume whole.
    /// `<frets>` has no such constraint and simply falls back to 0.
    static func decode(_ node: XMLTreeNode) -> StringData {
        let strings = node.all("string").map { child in
            InstrumentString(
                pitch: Int(child.text) ?? 0,
                isOpen: child.attributes["open"].flatMap(Int.init).map { $0 != 0 } ?? false,
                useFlat: child.attributes["useFlat"].flatMap(Int.init).map { $0 != 0 } ?? false,
            )
        }
        return StringData(
            frets: node.first("frets").flatMap { Int($0.text) } ?? 0,
            strings: strings,
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
    }
}
