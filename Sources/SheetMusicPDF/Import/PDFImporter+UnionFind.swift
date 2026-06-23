import Foundation

/// Minimal union-find over integer ids (stem indices) for grouping stems
/// joined by a shared beam (see `PDFImporter+BeamGroups`). Path-compressing
/// `find`; `union` attaches one root to the other.
struct UnionFind {
    private var parent: [Int: Int] = [:]

    init(ids: [Int]) {
        for id in ids {
            parent[id] = id
        }
    }

    mutating func find(_ x: Int) -> Int {
        var root = x
        while let p = parent[root], p != root {
            root = p
        }
        // Path compression.
        var cur = x
        while let p = parent[cur], p != root {
            parent[cur] = root
            cur = p
        }
        return root
    }

    mutating func union(_ a: Int, _ b: Int) {
        let ra = find(a)
        let rb = find(b)
        if ra != rb { parent[ra] = rb }
    }
}
