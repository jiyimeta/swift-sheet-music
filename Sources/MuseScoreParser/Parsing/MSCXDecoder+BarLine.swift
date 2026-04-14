import Foundation

extension BarLine {
    static func decode(_ node: XMLNode) throws -> BarLine {
        BarLine(subtype: node.first("subtype")?.text)
    }
}
