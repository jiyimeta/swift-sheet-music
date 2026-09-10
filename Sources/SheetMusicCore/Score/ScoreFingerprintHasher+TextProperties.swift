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
    /// staff/system text 95...99, harmony 100...104. Previous occupants end at note placement's tag 84.
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
}
