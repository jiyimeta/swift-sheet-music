/// UTC `YYYY-MM-DD` formatting without a date formatter.
///
/// `ISO8601DateFormatter` lives in the `Foundation` umbrella, which the
/// portable targets are moving off of. The MSCX encoder only ever needs the
/// full-date form in UTC, so plain integer arithmetic covers it and behaves
/// identically on every platform.
enum ISODate {
    /// The UTC calendar date of an instant, as `YYYY-MM-DD`.
    static func fullDate(secondsSince1970: Double) -> String {
        let days = Int((secondsSince1970 / 86400).rounded(.down))
        let (year, month, day) = civil(fromDaysSinceEpoch: days)
        return "\(pad(year, width: 4))-\(pad(month, width: 2))-\(pad(day, width: 2))"
    }

    /// Howard Hinnant's `civil_from_days`, shifted to an era starting
    /// 0000-03-01 so that leap days land at the end of the cycle. Valid for
    /// the whole range of dates the encoder could ever stamp.
    static func civil(fromDaysSinceEpoch days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthProxy = (5 * dayOfYear + 2) / 153

        let day = dayOfYear - (153 * monthProxy + 2) / 5 + 1
        let month = monthProxy + (monthProxy < 10 ? 3 : -9)
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }

    private static func pad(_ value: Int, width: Int) -> String {
        let text = String(value)
        guard text.count < width else { return text }
        return String(repeating: "0", count: width - text.count) + text
    }
}
