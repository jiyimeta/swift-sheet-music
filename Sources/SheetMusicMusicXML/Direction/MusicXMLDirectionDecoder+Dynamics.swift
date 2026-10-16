import SheetMusicCore
import SheetMusicFoundation

/// A direction's dynamics as MuseScore makes them (`MusicXmlParserDirection::direction`, `P2:3706-3761`): one per
/// entry of the dynamics list, each with the subtype and own words `Dynamic::setDynamicType` reads out of it, the
/// `<dynamics>` color, the direction's visibility and the `<sound dynamics>` velocity; a dynamic range is one dynamic.
extension MusicXMLDirectionDecoder {
    static func appendDynamics(
        _ facts: MusicXMLDirectionFacts, staff: Int, tick: Fraction, context: Context, to output: inout Output,
    ) {
        let isRange = isLikelyDynamicRange(facts, context: context)
        var made: [Dynamic] = []
        for (index, entry) in facts.dynamics.enumerated() {
            let dynamic = makeDynamic(from: entry, facts: facts)
            // The last of a range joins the first, after a hyphen (`P2:3725-3734`).
            if isRange, index == facts.dynamics.count - 1, var first = made.first {
                first.setCustomText(
                    xmlText: xmlText(of: first) + "<sym>dynamicCombinedSeparatorHyphen</sym>" + xmlText(of: dynamic),
                )
                made[0] = first
                continue
            }
            made.append(dynamic)
        }
        for dynamic in made {
            output.events.append(MusicXMLDirectionEvent(
                measure: context.measure, staff: staff, tick: tick, payload: .voice(.dynamic(dynamic)),
            ))
        }
    }

    /// `isLikelyDynamicRange` (`P2:4993-5005`): with inference, two dynamics and words that are only a hyphen or a dash
    /// once their tags are gone — "mp-f". It is a branch of the words' `else if` chain (`P2:3567-3568`), but the
    /// branches before it (a tempo text, a tempo line, a Sticking by their words) never take a lone dash, so it needs
    /// no check of them. A repeat direction's words are cleared before the chain.
    static func isLikelyDynamicRange(_ facts: MusicXMLDirectionFacts, context: Context) -> Bool {
        guard context.options.inferTextType, facts.dynamics.count == 2, !facts.sound.isRepeat else { return false }
        let raw = MusicXMLFormattedWords.simplified(withoutTags(MusicXMLFormattedWords.simplified(facts.wordsXML)))
        return raw == "-" || raw == "\u{2014}"
    }

    /// One list entry as a dynamic (`Dynamic::setDynamicType`, `engraving/dom/dynamic.cpp:231-241`): a known token
    /// gives the subtype and, with words around it, the dynamic's own text; none makes MuseScore's `OTHER` with the
    /// entry, as read, as its text.
    private static func makeDynamic(from entry: String, facts: MusicXMLDirectionFacts) -> Dynamic {
        let parsed = MusicXMLDynamicText.parse(entry)
        var dynamic = Dynamic(
            subtype: parsed.subtype, velocity: velocity(facts.dynamicsVelocity, subtype: parsed.subtype),
        )
        if parsed.subtype == "other-dynamics" {
            // `OTHER`'s own text is "", so an empty entry prints no words of its own (`hasCustomText`).
            if !entry.isEmpty { dynamic.setCustomText(xmlText: entry) }
        } else if let custom = parsed.customXML {
            dynamic.setCustomText(xmlText: custom)
        }
        dynamic.elementProperties.color = facts.dynamicsColor
        dynamic.visible = facts.visible
        return dynamic
    }

    /// `round(v × 0.9)` clamped to 0…127 (`P2:3736-3743`), stored as MuseScore stores it; a stored value of 0 or none
    /// plays the table's (`Dynamic::velocity`, `engraving/dom/dynamic.cpp:142-145`).
    private static func velocity(_ value: Double?, subtype: String) -> Int {
        let table = Dynamic.defaultVelocity(for: subtype)
        guard let value else { return table }
        let scaled = (value * 0.9).rounded()
        guard !scaled.isNaN else { return table }
        let stored = Int(min(max(scaled, 0), 127))
        return stored > 0 ? stored : table
    }

    /// `Dynamic::xmlText`: its own text, else its subtype's glyphs.
    private static func xmlText(of dynamic: Dynamic) -> String {
        dynamic.customXMLText ?? MusicXMLDynamicText.glyphs(dynamic.subtype)
    }
}
