import SheetMusicFoundation

/// A stable element identifier, byte-compatible with MuseScore's
/// `mu::engraving::EID`: two 64-bit halves serialized as base64 and joined
/// by `_`. Identifiers this library writes therefore survive a MuseScore
/// round trip, and identifiers MuseScore wrote are read back unchanged.
///
/// The halves are **opaque**. Only identifiers this library mints have
/// internal meaning (`first` is the actor, `second` its counter); MuseScore
/// mints both halves at random, so nothing may read a foreign identifier as
/// an actor and a counter.
///
/// C++: `mu::engraving::EID` (`infrastructure/eid.h`, `infrastructure/eid.cpp`).
public struct EID: Hashable, Sendable {
    public let first: UInt64
    public let second: UInt64

    public init(first: UInt64, second: UInt64) {
        self.first = first
        self.second = second
    }

    /// The sentinel MuseScore uses for "no identifier".
    public static let invalid = EID(first: .max, second: .max)

    /// True unless *both* halves are the sentinel — matching `EID::isValid`,
    /// which tests the halves with `||`.
    public var isValid: Bool {
        self != Self.invalid
    }
}

extension EID {
    /// Longest base64 rendering of a `UInt64` in this scheme: `ceil(64 / 6)`.
    /// C++: `EID::MAX_UINT64_BASE64_SIZE`.
    private static let maxHalfLength = 11

    private static let alphabet = Array(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
    )

    private static let digits: [Character: UInt64] = {
        var table: [Character: UInt64] = [:]
        for (index, character) in alphabet.enumerated() {
            table[character] = UInt64(index)
        }
        return table
    }()

    /// Least-significant digit first, and at least one digit for zero — the
    /// shape of the C++ `do`-`while`.
    private static func encode(_ value: UInt64) -> String {
        var remaining = value
        var characters: [Character] = []
        repeat {
            characters.append(alphabet[Int(remaining % 64)])
            remaining /= 64
        } while remaining != 0
        return String(characters)
    }

    private static func decode(_ text: Substring) -> UInt64? {
        guard !text.isEmpty, text.count <= maxHalfLength else { return nil }
        var result: UInt64 = 0
        for character in text.reversed() {
            guard let digit = digits[character] else { return nil }
            result = (result << 6) | digit
        }
        return result
    }

    public var stringValue: String {
        "\(Self.encode(first))_\(Self.encode(second))"
    }

    /// Fails rather than throwing: a string that is not an identifier means
    /// "this element has no identifier yet", which is a state the assignment
    /// pass fills, not an error that should abort a parse.
    public init?(string: String) {
        let halves = string.split(
            separator: "_", omittingEmptySubsequences: false,
        )
        guard halves.count == 2,
              let first = Self.decode(halves[0]),
              let second = Self.decode(halves[1])
        else { return nil }
        self.init(first: first, second: second)
    }
}
