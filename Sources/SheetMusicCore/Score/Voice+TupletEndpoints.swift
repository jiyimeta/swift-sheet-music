import SheetMusicFoundation

extension Voice {
    var hasUnassignedIDs: Bool {
        elements.hasUnassignedIDs || tuplets.hasUnassignedIDs || tuplets.contains {
            if case .index = $0.first { return true }
            if case .index = $0.last { return true }
            return false
        }
    }

    /// Mint members before their tuplets, resolving literal endpoints immediately after the member pass.
    mutating func assignMissingIDs(using ids: inout EIDAllocator) {
        elements.assignMissingIDs(using: &ids)
        resolveTupletEndpoints()
        tuplets.assignMissingIDs(using: &ids)
    }

    /// Drop unusable literal tuplets because readers never drew or encoded them.
    mutating func resolveTupletEndpoints() {
        let members = elements
        tuplets.removeAll { tuplet in
            var hasLiteralEndpoint = false
            for endpoint in [tuplet.first, tuplet.last] {
                if case let .index(index) = endpoint {
                    hasLiteralEndpoint = true
                    if !members.indices.contains(index) { return true }
                }
            }
            return hasLiteralEndpoint && tuplet.first.index(in: members) > tuplet.last.index(in: members)
        }
        for index in tuplets.indices {
            tuplets.updateValue(at: index) {
                $0.first = $0.first.resolved(in: members)
                $0.last = $0.last.resolved(in: members)
            }
        }
    }

    /// A replacement occupies the member's place in every span, even when its identity changes.
    mutating func replaceElement(at index: Int, with element: VoiceElement, id: EID) {
        let previous = elements.eid(at: index)
        elements.replaceSubrange(index ..< (index + 1), with: [(id, element)])
        guard previous != id else { return }
        tuplets.mapValues { tuplet in
            var result = tuplet
            if result.first == .element(previous) { result.first = .element(id) }
            if result.last == .element(previous) { result.last = .element(id) }
            return result
        }
    }

    /// Removed endpoints move to surviving members inside their old span. Empty spans disappear.
    /// The literal branch uses the same rule before score adoption, while slot IDs are still unassigned.
    mutating func removeElements(at indices: Set<Int>) {
        let removed = indices.intersection(elements.indices)
        guard !removed.isEmpty else { return }
        let spans = tupletSpans
        var dropped: [Int] = []
        for index in tuplets.indices {
            let span = spans[index]
            let survivors = elements.indices.filter {
                span.startIndex <= $0 && $0 <= span.endIndex && !removed.contains($0)
            }
            guard let first = survivors.first, let last = survivors.last else {
                dropped.append(index)
                continue
            }
            let firstEndpoint = inwardEndpoint(tuplets[index].first, at: first, removing: removed)
            let lastEndpoint = inwardEndpoint(tuplets[index].last, at: last, removing: removed)
            tuplets.updateValue(at: index) { tuplet in
                tuplet.first = firstEndpoint
                tuplet.last = lastEndpoint
            }
        }
        for index in dropped.reversed() {
            tuplets.removeSubrange(index ..< (index + 1))
        }
        for index in removed.sorted().reversed() {
            elements.removeSubrange(index ..< (index + 1))
        }
    }

    private func inwardEndpoint(
        _ endpoint: TupletEndpoint, at index: Int, removing removed: Set<Int>,
    ) -> TupletEndpoint {
        switch endpoint {
        case .element:
            .element(elements.eid(at: index))
        case .index:
            .index(index - removed.filter { $0 < index }.count)
        }
    }
}
