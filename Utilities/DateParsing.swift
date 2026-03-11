import Foundation

enum DateParsing {
    private static let dateDetector: NSDataDetector? = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.date.rawValue
    )

    static func parseDate(from text: String) -> Date? {
        guard let detector = dateDetector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.date
    }
}
