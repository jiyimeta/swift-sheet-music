import SheetMusicCore

extension LayoutEngine {
    /// Bar `measureIndex`'s rests that stand under a measure-repeat group's sign, on every staff — the first voice's
    /// rests in a bar of a group, which placement never draws (`LayoutMeasure.measureRepeatRests`). `addresses` pairs
    /// with `staves`.
    static func measureRepeatRests(at measureIndex: Int, staves: [Staff], addresses: [StaffAddress]) -> [RestID] {
        zip(staves, addresses).flatMap { staff, address -> [RestID] in
            guard staff.measures.indices.contains(measureIndex),
                  staff.measures[measureIndex].measureRepeatCount != nil,
                  let voice = staff.measures[measureIndex].voices.first
            else { return [] }
            return voice.elements.values.enumerated().compactMap { index, element in
                guard element.isRest else { return nil }
                return RestID(staff: address, measureIndex: measureIndex, voiceIndex: 0, elementIndex: index)
            }
        }
    }
}
