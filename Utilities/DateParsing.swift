import Foundation

enum DateParsing {
    private static let dateDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue
    )
    private static let monthNames: [String] = [
        "january", "february", "march", "april", "may", "june",
        "july", "august", "september", "october", "november", "december"
    ]
    private static let shortMonthNames: [String] = [
        "jan", "feb", "mar", "apr", "may", "jun",
        "jul", "aug", "sep", "oct", "nov", "dec"
    ]
    private static let monthDayPatterns: [String] = [
        #"\b(january|february|march|april|may|june|july|august|september|october|november|december)\s+([0-9]{1,2})\b"#,
        #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)\.?\s+([0-9]{1,2})\b"#
    ]

    static func parseDate(from text: String) -> Date? {
        guard let detector = dateDetector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        if let detected = detector.firstMatch(in: text, options: [], range: range)?.date {
            return detected
        }
        return parseMonthDayFallback(from: text)
    }

    private static func parseMonthDayFallback(from text: String) -> Date? {
        let lowered = text.lowercased()
        for pattern in monthDayPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(lowered.startIndex..., in: lowered)
            guard let match = regex.firstMatch(in: lowered, options: [], range: nsRange),
                  match.numberOfRanges >= 3,
                  let monthRange = Range(match.range(at: 1), in: lowered),
                  let dayRange = Range(match.range(at: 2), in: lowered),
                  let day = Int(lowered[dayRange]),
                  (1...31).contains(day)
            else { continue }

            let monthToken = String(lowered[monthRange])
            let monthNumber: Int?
            if let fullIndex = monthNames.firstIndex(of: monthToken) {
                monthNumber = fullIndex + 1
            } else if let shortIndex = shortMonthNames.firstIndex(of: monthToken.trimmingCharacters(in: .punctuationCharacters)) {
                monthNumber = shortIndex + 1
            } else {
                monthNumber = nil
            }

            guard let monthNumber else { continue }
            return makeDate(month: monthNumber, day: day)
        }
        return nil
    }

    private static func makeDate(month: Int, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let now = Date()
        let currentYear = calendar.component(.year, from: now)

        var components = DateComponents()
        components.year = currentYear
        components.month = month
        components.day = day
        guard var candidate = calendar.date(from: components) else { return nil }
        if candidate < calendar.date(byAdding: .day, value: -1, to: now) ?? now {
            components.year = currentYear + 1
            candidate = calendar.date(from: components) ?? candidate
        }
        return candidate
    }
}
