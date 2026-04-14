import Foundation
import SheetMusicCore

extension Spanner {
    static func decode(_ node: XMLNode) throws -> Spanner {
        let raw = node.attributes["type"] ?? ""
        let kind = Kind(rawValue: raw) ?? .other

        var voltaEndings: [Int] = []
        if let voltaNode = node.first("Volta") {
            let endingsText = voltaNode.first("endings")?.text ?? ""
            voltaEndings = endingsText
                .split(whereSeparator: { ", ".contains($0) })
                .compactMap { Int($0) }
        }

        let nextMeasures = Int(node.first("next")?.first("location")?.first("measures")?.text ?? "0") ?? 0

        return Spanner(
            kind: kind,
            rawType: raw,
            nextMeasuresOffset: nextMeasures,
            voltaEndings: voltaEndings
        )
    }
}
