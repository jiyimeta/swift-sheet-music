extension String {
    /// A substring test that needs neither Foundation nor `_StringProcessing`: the portable targets build for wasm
    /// and the tempo / technique tables are plain substring searches.
    func hasSubstring(_ needle: String) -> Bool {
        if needle.isEmpty { return true }
        var index = startIndex
        while index < endIndex {
            if self[index...].hasPrefix(needle) { return true }
            index = self.index(after: index)
        }
        return false
    }

    /// How many times `needle` occurs, counted without overlap from the start (`QString::count`).
    func occurrences(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var index = startIndex
        while index < endIndex {
            if self[index...].hasPrefix(needle) {
                count += 1
                index = self.index(index, offsetBy: needle.count)
            } else {
                index = self.index(after: index)
            }
        }
        return count
    }
}
