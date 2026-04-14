import Foundation

public enum MuseScoreParserError: Error, Sendable {
    case invalidXML(underlying: Error)
    case malformedScore(reason: String)
    case unsupportedFeature(name: String, location: String?)
}
