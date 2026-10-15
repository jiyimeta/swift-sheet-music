extension Spanner {
    /// The three texts a line spanner draws (begin, continuation at the start of a later system, end) as MuseScore
    /// xml text, the same storage as `beginText`; `nil` = nothing to draw.
    package struct LineLabels: Sendable, Equatable {
        package var begin: String?
        package var continuation: String?
        package var end: String?
    }

    // Defaults, named after the `Sid` (or class property default) they mirror.
    private static let pedalText = "<sym>keyboardPedalPed</sym>" // styledef.cpp:339
    private static let pedalContinueText = // styledef.cpp:341-342
        "<sym>keyboardPedalParensLeft</sym><sym>keyboardPedalPed</sym><sym>keyboardPedalParensRight</sym>"
    private static let pedalRosetteEndText = "<sym>keyboardPedalUp</sym>" // styledef.cpp:345
    private static let hairpinCrescText = "cresc." // styledef.cpp:304
    private static let hairpinDecrescText = "dim." // styledef.cpp:305
    private static let hairpinCrescContText = "(cresc.)" // styledef.cpp:306
    private static let hairpinDecrescContText = "(dim.)" // styledef.cpp:307
    private static let palmMuteText = "P.M." // styledef.cpp:1943
    private static let letRingText = "let ring" // styledef.cpp:1891
    private static let whammyBarText = "w/bar" // styledef.cpp:1917
    private static let rasgueadoText = "rasg" // rasgueado.cpp:133-135
    private static let pickScrapeText = "P.S." // pickscrape.cpp:133-135

    /// The texts MuseScore would draw for this line: the authored text where the file has one, else the kind's
    /// default (`propertyDefault` / `getPropertyStyle`). A pedal follows `Pedal::getPropertyStyle`
    /// (`dom/pedal.cpp:105-119`): begin and continue texts are the style's unless a begin hook is set (then the
    /// hook texts, empty), and the end text is empty while the line is visible and the rosette otherwise. Hairpin
    /// lines carry `cresc.` / `dim.` (`dom/hairpin.cpp:717-736`); a wedge, a text line, a harmonic mark and a
    /// volta (whose begin text is authored only, `dom/volta.cpp:139-151`) carry none. The end text of every kind
    /// other than a pedal defaults to none.
    package var lineLabels: LineLabels {
        let defaults = defaultLineLabels
        return LineLabels(
            begin: beginText ?? defaults.begin,
            continuation: continueText ?? defaults.continuation,
            end: endText ?? defaults.end,
        )
    }

    private var defaultLineLabels: LineLabels {
        switch kind {
        case .pedal:
            // `nil` line properties read exactly like an all-default `LineProperties()`.
            let hook = lineProperties?.beginHook ?? LineHookType.none
            let visible = lineProperties?.lineVisible ?? true
            return LineLabels(
                begin: hook == .none ? Self.pedalText : nil,
                continuation: hook == .none ? Self.pedalContinueText : nil,
                end: visible ? nil : Self.pedalRosetteEndText,
            )
        case .hairpin:
            switch hairpin?.subtype {
            case .crescLine: return LineLabels(begin: Self.hairpinCrescText, continuation: Self.hairpinCrescContText)
            case .dimLine: return LineLabels(begin: Self.hairpinDecrescText, continuation: Self.hairpinDecrescContText)
            case .crescendo, .decrescendo, nil: return LineLabels()
            }
        case .palmMute:
            return LineLabels(begin: Self.palmMuteText, continuation: Self.palmMuteText)
        case .letRing:
            return LineLabels(begin: Self.letRingText, continuation: Self.letRingText)
        case .chordTextLine:
            switch chordTextLine {
            case .whammyBar: return LineLabels(begin: Self.whammyBarText, continuation: Self.whammyBarText)
            case .rasgueado: return LineLabels(begin: Self.rasgueadoText, continuation: Self.rasgueadoText)
            case .pickScrape: return LineLabels(begin: Self.pickScrapeText, continuation: Self.pickScrapeText)
            case .harmonicMark, nil: return LineLabels()
            }
        case .textLine, .volta, .slur, .ottava, .glissando, .vibrato, .trill, .gradualTempoChange, .other:
            return LineLabels()
        }
    }
}
