import SheetMusicFoundation

/// MuseScore's `PlayingTechniqueType`: what a play-technique annotation ("pizz.", "arco", "mute") asks the instrument
/// to play with. A token this table does not know — MuseScore's own `undefined`, or one a later version adds — is kept
/// verbatim as `.other`, so it is written back as it was read.
package enum PlayingTechnique: Sendable, Equatable, Hashable {
    case natural, pizzicato, open, mute, tremolo, detache, martele, colLegno, sulPonticello, sulTasto, vibrato, legato
    case distortion, overdrive, harmonics, jazzTone
    case handbellsSwing, handbellsSwingUp, handbellsSwingDown, handbellsEcho1, handbellsEcho2, handbellsDamp
    case handbellsLV, handbellsR
    case other(String)

    /// `TConv::toXml(PlayingTechniqueType)` (`types/typesconv.cpp:2089-2115`).
    private static let tokens: [(PlayingTechnique, String)] = [
        (.natural, "natural"), (.pizzicato, "pizzicato"), (.open, "open"), (.mute, "mute"), (.tremolo, "tremolo"),
        (.detache, "detache"), (.martele, "martele"), (.colLegno, "col_legno"), (.sulPonticello, "sul_ponticello"),
        (.sulTasto, "sul_tasto"), (.vibrato, "vibrato"), (.legato, "legato"), (.distortion, "distortion"),
        (.overdrive, "overdrive"), (.harmonics, "harmonics"), (.jazzTone, "jazz_tone"),
        (.handbellsSwing, "handbells_swing"), (.handbellsSwingUp, "handbells_swing_up"),
        (.handbellsSwingDown, "handbells_swing_down"), (.handbellsEcho1, "handbells_echo_1"),
        (.handbellsEcho2, "handbells_echo_2"), (.handbellsDamp, "handbells_damp"), (.handbellsLV, "handbells_lv"),
        (.handbellsR, "handbells_r"),
    ]

    package var mscxToken: String {
        if case let .other(token) = self { return token }
        return Self.tokens.first { $0.0 == self }?.1 ?? ""
    }

    package init(mscxToken: String) {
        self = Self.tokens.first { $0.1 == mscxToken }?.0 ?? .other(mscxToken)
    }
}
