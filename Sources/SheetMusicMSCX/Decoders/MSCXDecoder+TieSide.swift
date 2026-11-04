import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// One half of a tie as the file wrote it, kept beside the decoded score until the ties are paired.
///
/// The model's tie is presence-only (`Note.tieForward` / `Note.tieBack`), so what the file says about where a side's
/// partner is — the `<location>` of a MuseScore 3 / 4 `<Spanner type="Tie">`, the id of a MuseScore 2 `<Tie>`, the
/// `<eid>`s of a MuseScore 5 `<Tie>` — is gone from the score. The pairing pass (`MSCXTiePairing`) still needs it: to
/// tell a tie the shared rule (`DetachedTies`) links as the file says from one it links elsewhere, and to say what
/// shape a tie it has to drop had.
struct MSCXTieSide {
    enum Side: String {
        case forward = "tieForward"
        case back = "tieBack"
    }

    /// A grace chord's place in its parent's runs, as `Chord.graceNotesBefore` / `graceNotesAfter` hold them.
    enum Grace: Hashable {
        case before(Int)
        case after(Int)
    }

    /// What the file names as this side's partner.
    enum Partner: Equatable {
        /// `<Spanner type="Tie">` with a `<location>` under `<next>` / `<prev>` (MuseScore 3 and 4).
        case location(Location)
        /// `<Spanner type="Tie">` whose `<next>` / `<prev>` carries no `<location>` — which MuseScore cannot connect.
        case missingLocation
        /// MuseScore 2's note-level `<Tie id="N">` on the start note and `<endSpanner id="N"/>` on the end note.
        case legacyID(String?)
        /// MuseScore 5's `<Tie>` on the end note: the start note's `<eid>`, which is also what a start side records.
        case museScore5(String)
    }

    /// The relative `<location>` MuseScore writes for a spanner end (`TWrite::write(const Location*, …)`): each
    /// field is the partner's minus this side's, and absent means zero.
    struct Location: Equatable {
        var staves = 0
        var voices = 0
        var measures = 0
        var fractions = Fraction(numerator: 0, denominator: 1)
        var grace: Int?
        var notes = 0
    }

    /// Where the note sits, filled in as the decode climbs from the chord to the part.
    struct Address: Hashable {
        var staff = 0
        var measure = 0
        var voice = 0
        var element: Int
        var grace: Grace?
        var pitch: Int
    }

    var side: Side
    var partner: Partner
    var address: Address
    /// Where the note's chord starts and ends within its measure: a `<location>` is relative to the start.
    var start: Fraction
    var end: Fraction

    /// The tie sides one `<Note>` carries, with their partners.
    ///
    /// The decoder's tie flags come from here too (`Note.decodeConnectors`), so what is recorded and what is decoded
    /// cannot disagree.
    static func read(_ note: XMLTreeNode) -> [(side: Side, partner: Partner)] {
        var sides: [(side: Side, partner: Partner)] = []
        for spanner in note.all("Spanner") where spanner.attributes["type"] == "Tie" {
            if let next = spanner.first("next") { sides.append((.forward, partner(of: next))) }
            if let prev = spanner.first("prev") { sides.append((.back, partner(of: prev))) }
        }
        // MuseScore 5 writes a tie once, on its END note, naming both notes by `<eid>`; a note-level `<Tie>` without
        // `<startElement>` is MuseScore 2's start side.
        for tie in note.all("Tie") {
            if let start = tie.first("startElement")?.text {
                sides.append((.back, .museScore5(start)))
            } else {
                sides.append((.forward, .legacyID(tie.attributes["id"])))
            }
        }
        if let eid = note.first(EIDXML.childName)?.text, MSCXParserContext.museScore5TieStarts?.contains(eid) == true {
            sides.append((.forward, .museScore5(eid)))
        }
        // MuseScore 2 ends a glissando with the same `<endSpanner id="N"/>` it ends a tie with, so an end is a tie's
        // only when its id names a `<Tie>` (`MSCXParserContext.legacyTieIDs`).
        let tieIDs = MSCXParserContext.legacyTieIDs
        if let end = note.all("endSpanner").first(where: { end in
            guard let tieIDs, let id = end.attributes["id"] else { return true }
            return tieIDs.contains(id)
        }) {
            sides.append((.back, .legacyID(end.attributes["id"])))
        }
        return sides
    }

    private static func partner(of end: XMLTreeNode) -> Partner {
        guard let node = end.first("location") else { return .missingLocation }
        var location = Location()
        location.staves = node.first("staves").flatMap { Int($0.text) } ?? 0
        location.voices = node.first("voices").flatMap { Int($0.text) } ?? 0
        location.measures = node.first("measures").flatMap { Int($0.text) } ?? 0
        location.fractions = node.first("fractions").flatMap { Fraction(mscxString: $0.text) } ?? location.fractions
        location.grace = node.first("grace").flatMap { Int($0.text) }
        location.notes = node.first("notes").flatMap { Int($0.text) } ?? 0
        return .location(location)
    }

    /// The sides of every note of a chord or grace chord whose element is `element` in its voice.
    static func record(
        _ chord: XMLTreeNode, element: Int, grace: Grace?, start: Fraction, end: Fraction,
    ) -> [MSCXTieSide] {
        chord.all("Note").flatMap { note -> [MSCXTieSide] in
            guard let pitch = note.first("pitch").flatMap({ Int($0.text) }) else { return [] }
            return read(note).map {
                MSCXTieSide(
                    side: $0.side, partner: $0.partner,
                    address: Address(element: element, grace: grace, pitch: pitch), start: start, end: end,
                )
            }
        }
    }
}

extension [MSCXTieSide] {
    /// The same sides with one more level of their address filled in.
    func stamped(_ keyPath: WritableKeyPath<MSCXTieSide.Address, Int>, _ value: Int) -> [MSCXTieSide] {
        map { side in
            var side = side
            side.address[keyPath: keyPath] = value
            return side
        }
    }
}
