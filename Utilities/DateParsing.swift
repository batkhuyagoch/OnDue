import Foundation

enum DateParsing {
    static func parseDate(from text: String) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let match = detector.matches(in: text, options: [], range: range).first
        return match?.date
    }
}
