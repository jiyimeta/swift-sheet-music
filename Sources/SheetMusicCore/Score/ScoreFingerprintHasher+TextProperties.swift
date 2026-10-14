import SheetMusicFoundation

extension FNV1a {
    /// Harmony's existing prefix stays byte-identical; append only authored font occupants.
    mutating func combine(_ harmony: Harmony) {
        combine(harmony.name)
        combine(harmony.harmonyType.rawValue)
        combinePresence(harmony.rootTpc)
        combinePresence(harmony.bassTpc)
        combine(harmony.visible)
        combineOccupied(harmony.elementProperties, colorTag: 67, placementTag: 83)
        combineOccupied(harmony.properties, firstTag: 100)
    }

    /// Five consecutive tags per carrier: lyric 85...89, rehearsal mark 90...94,
    /// staff/system text 95...99, harmony 100...104, tempo 106...110 (tempo's color is 105).
    /// Previous occupants end at note placement's tag 84.
    /// Nil emits nothing, including no presence byte: scores without overrides retain their committed hashes.
    /// Explicit empty strings, zero sizes/styles/padding and frame .none are occupants, not inheritance.
    mutating func combineOccupied(_ properties: TextProperties, firstTag: Int) {
        if let face = properties.face {
            combine(firstTag)
            combine(face)
        }
        if let size = properties.size {
            combine(firstTag + 1)
            combine(size)
        }
        if let style = properties.style {
            combine(firstTag + 2)
            combine(style.rawValue)
        }
        if let frameType = properties.frameType {
            combine(firstTag + 3)
            combine(frameType.rawValue)
        }
        if let framePadding = properties.framePadding {
            combine(firstTag + 4)
            combine(framePadding)
        }
    }

    /// A color alone, for a carrier whose visibility and placement no command writes — the tempo marking.
    /// Same bytes as the color half of `combineOccupied(_:colorTag:placementTag:)`, and the same nil rule.
    mutating func combineOccupiedColor(_ color: ScoreColor?, tag: Int) {
        guard let color else { return }
        combine(tag)
        combine(color.red)
        combine(color.green)
        combine(color.blue)
        combine(color.alpha)
    }

    /// A tempo marking's text fields, by occupants: authored text 111, a marking that does not follow its text 112, a
    /// text type other than `.normal` 113 and a marking left out of playback 114 — the four things `SetTempo` writes
    /// beside the number. A derived, playing, ordinary marking that follows its text feeds nothing, so every tempo
    /// built in code keeps the hash it had. The preserved markup is source-only and stays out, as on every carrier.
    mutating func combineOccupiedTempoText(_ tempo: Tempo) {
        if let text = tempo.text {
            combine(111)
            combine(text)
        }
        if !tempo.followText {
            combine(112)
        }
        if tempo.textType != .normal {
            combine(113)
            combine(tempo.textType.rawValue)
        }
        if !tempo.playsBack {
            combine(114)
        }
    }
}
