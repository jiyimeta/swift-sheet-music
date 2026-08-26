import Foundation
@testable import SheetMusicMSCX
import Testing

/// `ISODate` replaces `ISO8601DateFormatter(.withFullDate, UTC)` on the MSCX
/// export path. The formatter is the oracle where it exists.
@Suite("ISODate matches ISO8601DateFormatter")
struct ISODateTests {
    @Test("known dates format as YYYY-MM-DD in UTC")
    func knownDates() {
        // Epoch, and dates whose day rolls only in UTC.
        #expect(ISODate.fullDate(secondsSince1970: 0) == "1970-01-01")
        #expect(ISODate.fullDate(secondsSince1970: 86399) == "1970-01-01")
        #expect(ISODate.fullDate(secondsSince1970: 86400) == "1970-01-02")
        // Leap-day boundaries, including the century that is not a leap year.
        #expect(ISODate.fullDate(secondsSince1970: 951_782_400) == "2000-02-29")
        #expect(ISODate.fullDate(secondsSince1970: 1_709_164_800) == "2024-02-29")
        // Pre-epoch, where the day count floors rather than truncates.
        #expect(ISODate.fullDate(secondsSince1970: -1) == "1969-12-31")
        #expect(ISODate.fullDate(secondsSince1970: -86400) == "1969-12-31")
        #expect(ISODate.fullDate(secondsSince1970: -86401) == "1969-12-30")
    }

    #if canImport(Darwin)
        @Test("sweeps 1970 through 2100 against ISO8601DateFormatter")
        func differentialSweep() {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = TimeZone(identifier: "UTC")

            // Every 97th day is coprime with 7, 30 and 365, so the sweep walks
            // every weekday, month length and leap phase.
            var day = 0
            while day < 47500 {
                let seconds = Double(day) * 86400
                let expected = formatter.string(from: Date(timeIntervalSince1970: seconds))
                #expect(ISODate.fullDate(secondsSince1970: seconds) == expected, "day \(day)")
                day += 97
            }
        }

        @Test("leap boundaries match the formatter exactly")
        func leapBoundaries() {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            formatter.timeZone = TimeZone(identifier: "UTC")

            let interesting = [
                "1999-12-31",
                "2000-02-28",
                "2000-02-29",
                "2000-03-01",
                "2024-02-29",
                "2099-12-31",
                "2100-02-28",
                "2100-03-01",
            ]
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withFullDate]
            parser.timeZone = TimeZone(identifier: "UTC")

            for text in interesting {
                guard let date = parser.date(from: text) else {
                    Issue.record("could not parse \(text)")
                    continue
                }
                let seconds = date.timeIntervalSince1970
                #expect(ISODate.fullDate(secondsSince1970: seconds) == text)
                #expect(formatter.string(from: date) == text)
            }
        }
    #endif
}
