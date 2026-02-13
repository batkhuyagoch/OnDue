import Foundation

/// Extracts dates and deadlines from email text
final class DateExtractor {
    
    private let calendar = Calendar.current
    
    /// Extract potential deadline dates from text
    func extractDeadlines(from text: String, referenceDate: Date = Date()) -> [Date] {
        var dates: [Date] = []
        
        // Use NSDataDetector to find dates
        dates.append(contentsOf: extractDatesWithDataDetector(from: text))
        
        // Extract relative dates ("next Friday", "in 3 days")
        dates.append(contentsOf: extractRelativeDates(from: text, referenceDate: referenceDate))
        
        // Extract common deadline phrases
        dates.append(contentsOf: extractDeadlineKeywords(from: text, referenceDate: referenceDate))
        
        // Remove duplicates and sort
        let uniqueDates = Array(Set(dates)).sorted()
        
        // Filter out dates in the past (more than 1 day ago) and too far future (> 2 years)
        let oneDayAgo = calendar.date(byAdding: .day, value: -1, to: referenceDate) ?? referenceDate
        let twoYearsFromNow = calendar.date(byAdding: .year, value: 2, to: referenceDate) ?? referenceDate
        
        return uniqueDates.filter { date in
            date > oneDayAgo && date < twoYearsFromNow
        }
    }
    
    /// Extract renewal period from text ("annually", "monthly", etc.)
    func extractRenewalPeriod(from text: String) -> DateComponents? {
        let lowercased = text.lowercased()
        
        if lowercased.contains("annually") || lowercased.contains("annual") || lowercased.contains("yearly") {
            return DateComponents(year: 1)
        }
        if lowercased.contains("monthly") {
            return DateComponents(month: 1)
        }
        if lowercased.contains("quarterly") {
            return DateComponents(month: 3)
        }
        if lowercased.contains("bi-annual") || lowercased.contains("biannual") {
            return DateComponents(month: 6)
        }
        if lowercased.contains("weekly") {
            return DateComponents(weekOfYear: 1)
        }
        
        return nil
    }
    
    // MARK: - Private Helpers
    
    private func extractDatesWithDataDetector(from text: String) -> [Date] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return []
        }
        
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        
        return matches.compactMap { match in
            match.date
        }
    }
    
    private func extractRelativeDates(from text: String, referenceDate: Date) -> [Date] {
        var dates: [Date] = []
        let lowercased = text.lowercased()
        
        // "today", "tomorrow", "tonight"
        if lowercased.contains("today") || lowercased.contains("tonight") {
            dates.append(calendar.startOfDay(for: referenceDate))
        }
        if lowercased.contains("tomorrow") {
            if let tomorrow = calendar.date(byAdding: .day, value: 1, to: referenceDate) {
                dates.append(calendar.startOfDay(for: tomorrow))
            }
        }
        
        // "next week", "next month"
        if lowercased.contains("next week") {
            if let nextWeek = calendar.date(byAdding: .weekOfYear, value: 1, to: referenceDate) {
                dates.append(nextWeek)
            }
        }
        if lowercased.contains("next month") {
            if let nextMonth = calendar.date(byAdding: .month, value: 1, to: referenceDate) {
                dates.append(nextMonth)
            }
        }
        
        // "in X days/weeks/months"
        dates.append(contentsOf: extractInXTimePattern(from: lowercased, referenceDate: referenceDate))
        
        // Day names: "monday", "tuesday", etc.
        dates.append(contentsOf: extractDayNames(from: lowercased, referenceDate: referenceDate))
        
        return dates
    }
    
    private func extractInXTimePattern(from text: String, referenceDate: Date) -> [Date] {
        var dates: [Date] = []
        
        // Pattern: "in 3 days", "in 2 weeks", "in 1 month"
        let pattern = #"in (\d+) (day|days|week|weeks|month|months)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        
        for match in matches {
            guard match.numberOfRanges == 3,
                  let numberRange = Range(match.range(at: 1), in: text),
                  let unitRange = Range(match.range(at: 2), in: text) else {
                continue
            }
            
            let numberString = String(text[numberRange])
            let unit = String(text[unitRange])
            
            guard let number = Int(numberString) else { continue }
            
            var component: Calendar.Component?
            if unit.hasPrefix("day") {
                component = .day
            } else if unit.hasPrefix("week") {
                component = .weekOfYear
            } else if unit.hasPrefix("month") {
                component = .month
            }
            
            if let component = component,
               let date = calendar.date(byAdding: component, value: number, to: referenceDate) {
                dates.append(date)
            }
        }
        
        return dates
    }
    
    private func extractDayNames(from text: String, referenceDate: Date) -> [Date] {
        var dates: [Date] = []
        
        let dayNames = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"]
        
        for (index, dayName) in dayNames.enumerated() {
            if text.contains(dayName) {
                // Find next occurrence of this weekday
                let targetWeekday = index + 2 // weekday starts at 1 (Sunday), our array starts with Monday
                if let nextDate = calendar.nextDate(
                    after: referenceDate,
                    matching: DateComponents(weekday: targetWeekday),
                    matchingPolicy: .nextTime
                ) {
                    dates.append(nextDate)
                }
            }
        }
        
        return dates
    }
    
    private func extractDeadlineKeywords(from text: String, referenceDate: Date) -> [Date] {
        var dates: [Date] = []
        let lowercased = text.lowercased()
        
        // "by EOD" (end of day) or "by end of day"
        if lowercased.contains("by eod") || lowercased.contains("by end of day") || lowercased.contains("by end of business") {
            // Set to 5 PM today
            var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            components.hour = 17
            components.minute = 0
            if let eodDate = calendar.date(from: components) {
                dates.append(eodDate)
            }
        }
        
        // "by COB" (close of business)
        if lowercased.contains("by cob") || lowercased.contains("close of business") {
            var components = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            components.hour = 17
            components.minute = 0
            if let cobDate = calendar.date(from: components) {
                dates.append(cobDate)
            }
        }
        
        // "end of week"
        if lowercased.contains("end of week") || lowercased.contains("by friday") {
            if let friday = calendar.nextDate(
                after: referenceDate,
                matching: DateComponents(weekday: 6), // Friday
                matchingPolicy: .nextTime
            ) {
                dates.append(friday)
            }
        }
        
        // "end of month"
        if lowercased.contains("end of month") {
            var components = calendar.dateComponents([.year, .month], from: referenceDate)
            components.month! += 1
            components.day = 0 // Last day of current month
            if let endOfMonth = calendar.date(from: components) {
                dates.append(endOfMonth)
            }
        }
        
        return dates
    }
}
