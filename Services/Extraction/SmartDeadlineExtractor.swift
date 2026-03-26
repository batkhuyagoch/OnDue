import Foundation
import GRDB

enum DeadlineSource: String, Codable, Hashable {
    case subjectKeyword
    case htmlTableLabel
    case actionableWindow
    case bodyDateExtractor
    case bodyFallback
}

struct DeadlineResult: Hashable {
    let date: Date
    let source: DeadlineSource
}

enum SmartDeadlineExtractor {

    private static let deadlineKeywords = [
        "due", "due by", "due date", "deadline", "expires", "expiration",
        "before", "no later than", "pay by", "respond by", "submit by",
        "renew before", "renew by", "must be received", "by "
    ]

    private static let antiPatterns = [
        "statement period", "period ending", "period end", "as of",
        "generated on", "sent on", "sent:", "date:", "created on",
        "since", "from the period", "billing period", "cycle ending",
        "transaction on", "transaction date", "posted on", "ordered on",
        "purchased on", "shipped on",
        "paid on", "paid your", "payment received", "payment of",
        "receipt for", "receipt from", "receipt on"
    ]

    private static let htmlTableRegexes: [NSRegularExpression] = {
        let patterns = [
            #"<t[hd][^>]*>[^<]*(due\s*date|payment\s*due|due\s*by|deadline|expir(?:es?|ation)|pay\s*by)[^<]*</t[hd]>\s*<t[hd][^>]*>([^<]+)</t[hd]>"#,
            #"<t[hd][^>]*>[^<]*(due|deadline|expir(?:es?|ation))[^<]*:\s*([A-Z][a-z]+\s+\d{1,2}[^<]*)</t[hd]>"#
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    private static let dateExtractor = DateExtractor()

    // MARK: - Public API

    static func extract(
        subject: String,
        bodyHtml: String?,
        actionableWindowText: String?,
        normalizedText: String,
        referenceDate: Date = Date()
    ) -> DeadlineResult? {
        if let result = extractFromSubject(subject, referenceDate: referenceDate) {
            return result
        }
        if let html = bodyHtml,
           let result = extractFromHtmlTable(html, referenceDate: referenceDate) {
            return result
        }
        if let windowText = actionableWindowText,
           let result = extractFromActionableWindow(windowText, referenceDate: referenceDate) {
            return result
        }
        if let result = extractFromFullBody(normalizedText, referenceDate: referenceDate) {
            return result
        }
        if let result = extractFallback(normalizedText, referenceDate: referenceDate) {
            return result
        }
        return nil
    }

    // MARK: - Layer 1: Subject line

    private static func extractFromSubject(_ subject: String, referenceDate: Date) -> DeadlineResult? {
        let lower = subject.lowercased()
        guard deadlineKeywords.contains(where: { lower.contains($0) }) else { return nil }

        let explicit = parseExplicitDates(in: subject, referenceDate: referenceDate)
        if !explicit.isEmpty {
            var bestDate: Date?
            var bestDistance = Int.max
            for date in explicit {
                if isNearAntiPattern(date: date, in: lower) { continue }
                if let dist = distanceToNearestKeyword(date: date, in: lower), dist < bestDistance {
                    bestDistance = dist
                    bestDate = date
                }
            }
            if let date = bestDate { return DeadlineResult(date: date, source: .subjectKeyword) }
            return nil
        }

        // Text contained a date-like pattern that didn't produce valid dates (e.g. Feb 30).
        // Don't fall through to NSDataDetector which would leniently produce a rolled-over date.
        if containsDateLikePattern(in: lower) { return nil }

        // No explicit date pattern at all: try relative dates from DateExtractor
        // (e.g. "in 3 days", "next Friday", "by EOD").
        let dates = dateExtractor.extractDeadlines(from: subject, referenceDate: referenceDate)
        for date in dates {
            if !isNearAntiPattern(date: date, in: lower) {
                return DeadlineResult(date: date, source: .subjectKeyword)
            }
        }
        return nil
    }

    // MARK: - Layer 2: HTML table labels

    private static func extractFromHtmlTable(_ html: String, referenceDate: Date) -> DeadlineResult? {
        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)

        for regex in htmlTableRegexes {
            let matches = regex.matches(in: html, range: nsRange)
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let labelRange = Range(match.range(at: 1), in: html),
                      let valueRange = Range(match.range(at: 2), in: html) else { continue }

                let label = String(html[labelRange]).lowercased()
                if antiPatterns.contains(where: { label.contains($0) }) { continue }

                let valueText = String(html[valueRange])
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                let dates = dateExtractor.extractDeadlines(from: valueText, referenceDate: referenceDate)
                if let date = dates.first {
                    return DeadlineResult(date: date, source: .htmlTableLabel)
                }
            }
        }
        return nil
    }

    // MARK: - Layer 3: Actionable window text

    private static func extractFromActionableWindow(_ windowText: String, referenceDate: Date) -> DeadlineResult? {
        let lower = windowText.lowercased()

        let explicit = parseExplicitDates(in: windowText, referenceDate: referenceDate)
        let candidates: [Date]
        if !explicit.isEmpty {
            candidates = explicit
        } else if containsDateLikePattern(in: lower) {
            candidates = []
        } else {
            candidates = dateExtractor.extractDeadlines(from: windowText, referenceDate: referenceDate)
        }

        guard !candidates.isEmpty else { return nil }

        var bestDate: Date?
        var bestDistance = Int.max

        for date in candidates {
            if isNearAntiPattern(date: date, in: lower) { continue }
            let distance = distanceToNearestKeyword(date: date, in: lower)
            if let dist = distance, dist < bestDistance {
                bestDistance = dist
                bestDate = date
            }
        }

        if let date = bestDate {
            return DeadlineResult(date: date, source: .actionableWindow)
        }

        let nonAntiDates = candidates.filter { !isNearAntiPattern(date: $0, in: lower) }
        if let date = nonAntiDates.first {
            return DeadlineResult(date: date, source: .actionableWindow)
        }
        return nil
    }

    // MARK: - Layer 4: Full body via DateExtractor

    private static func extractFromFullBody(_ text: String, referenceDate: Date) -> DeadlineResult? {
        let lower = text.lowercased()

        let explicit = parseExplicitDates(in: text, referenceDate: referenceDate)
        let candidates: [Date]
        if !explicit.isEmpty {
            candidates = explicit
        } else if containsDateLikePattern(in: lower) {
            candidates = []
        } else {
            candidates = dateExtractor.extractDeadlines(from: text, referenceDate: referenceDate)
        }

        guard !candidates.isEmpty else { return nil }

        let filtered = candidates.filter { !isNearAntiPattern(date: $0, in: lower) }
        guard !filtered.isEmpty else { return nil }

        let sixMonths = Calendar.current.date(byAdding: .month, value: 6, to: referenceDate) ?? referenceDate
        let nearFuture = filtered.filter { $0 > referenceDate && $0 <= sixMonths }

        let pool = nearFuture.isEmpty ? filtered : nearFuture

        var bestDate: Date?
        var bestDistance = Int.max
        for date in pool {
            if let dist = distanceToNearestKeyword(date: date, in: lower), dist < bestDistance {
                bestDistance = dist
                bestDate = date
            }
        }

        if let date = bestDate {
            return DeadlineResult(date: date, source: .bodyDateExtractor)
        }
        if let first = pool.first {
            return DeadlineResult(date: first, source: .bodyDateExtractor)
        }
        return nil
    }

    // MARK: - Layer 5: Fallback

    private static func extractFallback(_ text: String, referenceDate: Date) -> DeadlineResult? {
        let lower = text.lowercased()
        if containsDateLikePattern(in: lower) { return nil }
        guard let date = DateParsing.parseDate(from: text, referenceDate: referenceDate) else { return nil }
        if isNearAntiPattern(date: date, in: lower) { return nil }
        return DeadlineResult(date: date, source: .bodyFallback)
    }

    // MARK: - Explicit date parsing (regex-based, no NSDataDetector)

    /// Returns true when the text contains a month-name + day pattern, even if the
    /// date is impossible (like Feb 30). Used to prevent NSDataDetector fallthrough
    /// when the explicit parser already rejected an invalid date.
    private static let dateLikePatternRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b\.?\s+\d{1,2}"#,
        options: .caseInsensitive
    )

    private static func containsDateLikePattern(in lowercasedText: String) -> Bool {
        guard let regex = dateLikePatternRegex else { return false }
        let range = NSRange(lowercasedText.startIndex..., in: lowercasedText)
        return regex.firstMatch(in: lowercasedText, range: range) != nil
    }

    private static let explicitMonthMap: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2,
        "mar": 3, "march": 3, "apr": 4, "april": 4, "may": 5,
        "jun": 6, "june": 6, "jul": 7, "july": 7,
        "aug": 8, "august": 8, "sep": 9, "september": 9,
        "oct": 10, "october": 10, "nov": 11, "november": 11,
        "dec": 12, "december": 12
    ]

    private static let explicitDateRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:tember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\b\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?"#,
        options: .caseInsensitive
    )

    /// Matches M/D, M/D/YY, M/D/YYYY, MM/DD, MM/DD/YY, MM/DD/YYYY.
    /// Negative lookbehind/ahead prevents matching inside URLs, version numbers, etc.
    private static let numericDateRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"(?<![/\d])(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?(?![/\d])"#,
        options: []
    )

    /// Parses explicit date patterns (month-name and numeric) from text using regex.
    /// Returns dates at noon local time, avoiding NSDataDetector phantom dates and
    /// timezone-dependent off-by-one-day errors.
    private static func parseExplicitDates(in text: String, referenceDate: Date) -> [Date] {
        let lower = text.lowercased()
        let cal = Calendar.current
        let refYear = cal.component(.year, from: referenceDate)
        let oneDayAgo = cal.date(byAdding: .day, value: -1, to: referenceDate) ?? referenceDate
        let twoYearsFromNow = cal.date(byAdding: .year, value: 2, to: referenceDate) ?? referenceDate

        var results: [Date] = []

        if let regex = explicitDateRegex {
            let nsRange = NSRange(lower.startIndex..., in: lower)
            let matches = regex.matches(in: lower, options: [], range: nsRange)
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let monthRange = Range(match.range(at: 1), in: lower),
                      let dayRange = Range(match.range(at: 2), in: lower) else { continue }
                let monthStr = String(lower[monthRange])
                guard let month = explicitMonthMap[monthStr] else { continue }
                guard let day = Int(String(lower[dayRange])), (1...31).contains(day) else { continue }

                var year = refYear
                var yearWasExplicit = false
                if match.numberOfRanges >= 4,
                   let yearRange = Range(match.range(at: 3), in: lower),
                   let explicit = Int(String(lower[yearRange])) {
                    year = explicit
                    yearWasExplicit = true
                }

                if let date = buildValidatedDate(month: month, day: day, year: year,
                                                  yearExplicit: yearWasExplicit,
                                                  oneDayAgo: oneDayAgo, twoYears: twoYearsFromNow,
                                                  cal: cal) {
                    results.append(date)
                }
            }
        }

        if let numRegex = numericDateRegex {
            let nsRange = NSRange(lower.startIndex..., in: lower)
            let matches = numRegex.matches(in: lower, options: [], range: nsRange)
            for match in matches {
                guard match.numberOfRanges >= 3,
                      let mRange = Range(match.range(at: 1), in: lower),
                      let dRange = Range(match.range(at: 2), in: lower) else { continue }
                guard let month = Int(String(lower[mRange])), (1...12).contains(month) else { continue }
                guard let day = Int(String(lower[dRange])), (1...31).contains(day) else { continue }

                var year = refYear
                var yearWasExplicit = false
                if match.numberOfRanges >= 4,
                   let yRange = Range(match.range(at: 3), in: lower),
                   var explicitYear = Int(String(lower[yRange])) {
                    if explicitYear < 100 { explicitYear += 2000 }
                    year = explicitYear
                    yearWasExplicit = true
                }

                if let date = buildValidatedDate(month: month, day: day, year: year,
                                                  yearExplicit: yearWasExplicit,
                                                  oneDayAgo: oneDayAgo, twoYears: twoYearsFromNow,
                                                  cal: cal) {
                    results.append(date)
                }
            }
        }

        return results
    }

    /// Builds a Date from components and validates it is a real calendar date
    /// (rejects impossible dates like Feb 30). Returns nil for invalid or out-of-range dates.
    private static func buildValidatedDate(
        month: Int, day: Int, year: Int,
        yearExplicit: Bool,
        oneDayAgo: Date, twoYears: Date,
        cal: Calendar
    ) -> Date? {
        var comps = DateComponents()
        comps.month = month
        comps.day = day
        comps.hour = 12

        comps.year = year
        if let date = cal.date(from: comps) {
            guard cal.component(.month, from: date) == month,
                  cal.component(.day, from: date) == day else { return nil }
            if date > oneDayAgo, date < twoYears { return date }
        }
        if !yearExplicit {
            comps.year = year + 1
            if let next = cal.date(from: comps) {
                guard cal.component(.month, from: next) == month,
                      cal.component(.day, from: next) == day else { return nil }
                if next < twoYears { return next }
            }
        }
        return nil
    }

    // MARK: - Anti-pattern exclusion

    static func isNearAntiPattern(date: Date, in text: String) -> Bool {
        let dateStrings = formattedVariants(for: date)
        let sentenceBoundaries: [Character] = [".", ";", "\n", "!"]
        for dateString in dateStrings {
            guard let range = text.range(of: dateString) else { continue }
            let lookbackStart = text.index(range.lowerBound, offsetBy: -60, limitedBy: text.startIndex) ?? text.startIndex
            let lookbackSlice = text[lookbackStart..<range.lowerBound]

            let effectiveStart: String.Index
            if let lastBoundary = lookbackSlice.lastIndex(where: { sentenceBoundaries.contains($0) }) {
                effectiveStart = text.index(after: lastBoundary)
            } else {
                effectiveStart = lookbackStart
            }

            let prefix = String(text[effectiveStart..<range.lowerBound]).lowercased()
            if antiPatterns.contains(where: { prefix.contains($0) }) {
                return true
            }
        }
        return false
    }

    // MARK: - Keyword proximity

    private static func distanceToNearestKeyword(date: Date, in text: String) -> Int? {
        let dateStrings = formattedVariants(for: date)
        var minDistance = Int.max

        for dateString in dateStrings {
            var searchStart = text.startIndex
            while let dateRange = text.range(of: dateString, range: searchStart..<text.endIndex) {
                let datePos = text.distance(from: text.startIndex, to: dateRange.lowerBound)
                for keyword in deadlineKeywords {
                    var kwStart = text.startIndex
                    while let kwRange = text.range(of: keyword, range: kwStart..<text.endIndex) {
                        let kwPos = text.distance(from: text.startIndex, to: kwRange.lowerBound)
                        let dist = abs(datePos - kwPos)
                        minDistance = min(minDistance, dist)
                        kwStart = kwRange.upperBound
                    }
                }
                searchStart = dateRange.upperBound
            }
        }
        return minDistance == Int.max ? nil : minDistance
    }

    // MARK: - Date formatting helpers

    private static let monthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM d"
        return f
    }()

    private static let shortMonthDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f
    }()

    private static let slashFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "M/d"
        return f
    }()

    private static let zeroPaddedSlashFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MM/dd"
        return f
    }()

    private static func formattedVariants(for date: Date) -> [String] {
        let variants = [
            monthDayFormatter.string(from: date).lowercased(),
            shortMonthDayFormatter.string(from: date).lowercased(),
            slashFormatter.string(from: date).lowercased(),
            zeroPaddedSlashFormatter.string(from: date).lowercased()
        ]
        return Array(Set(variants))
    }

    // MARK: - One-time re-extraction

    private static let reextractCompletedKey = "SmartDeadlineExtractor.reextractCompleted_v1"
    private static let batchSize = 50

    static var needsReextraction: Bool {
        !UserDefaults.standard.bool(forKey: reextractCompletedKey)
    }

    static func reextractAll(database: Database) async {
        guard needsReextraction else { return }

        do {
            var processed = 0
            while true {
                let batch: [(id: String, messagePk: Int64)] = try await database.readAsync { db in
                    try Row
                        .fetchAll(db, sql: """
                            SELECT id, messagePk FROM obligation
                            WHERE deadlineSource IS NULL
                            LIMIT ?
                        """, arguments: [batchSize])
                        .map { (id: $0["id"], messagePk: $0["messagePk"]) }
                }

                guard !batch.isEmpty else { break }

                for entry in batch {
                    guard let message: MessageRecord = try? await database.readAsync({ db in
                        try MessageRecord.fetchOne(db, key: ["pk": entry.messagePk])
                    }) else {
                        try? await database.writeAsync { db in
                            try db.execute(
                                sql: "UPDATE obligation SET deadlineSource = ? WHERE id = ?",
                                arguments: [DeadlineSource.bodyFallback.rawValue, entry.id]
                            )
                        }
                        continue
                    }

                    let parser = EmailParser()
                    let parsed = parser.parse(message: message)

                    let result = SmartDeadlineExtractor.extract(
                        subject: message.subject,
                        bodyHtml: message.bodyHtml,
                        actionableWindowText: parsed.actionableWindowText,
                        normalizedText: parsed.normalizedText,
                        referenceDate: message.internalDate
                    )

                    try? await database.writeAsync { db in
                        if let result {
                            try db.execute(
                                sql: "UPDATE obligation SET deadlineAt = ?, deadlineSource = ? WHERE id = ?",
                                arguments: [result.date, result.source.rawValue, entry.id]
                            )
                        } else {
                            try db.execute(
                                sql: "UPDATE obligation SET deadlineSource = ? WHERE id = ?",
                                arguments: [DeadlineSource.bodyFallback.rawValue, entry.id]
                            )
                        }
                    }
                }

                processed += batch.count
                await Task.yield()
            }

            if processed > 0 {
                AppLog.info("SmartDeadlineExtractor.reextractAll completed", fields: ["processed": processed])
            }
            UserDefaults.standard.set(true, forKey: reextractCompletedKey)
        } catch {
            AppLog.info("SmartDeadlineExtractor.reextractAll failed", fields: ["error": error.localizedDescription])
        }
    }
}
