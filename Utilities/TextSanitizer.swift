import Foundation
import UIKit

enum TextSanitizer {
    static func sanitizeMessage(bodyText: String?, bodyHtml: String?, snippet: String?) -> String? {
        if let bodyText, !bodyText.isEmpty {
            return sanitize(bodyText)
        }
        if let bodyHtml, !bodyHtml.isEmpty, let htmlText = htmlToText(bodyHtml) {
            return sanitize(htmlText)
        }
        if let snippet, !snippet.isEmpty {
            return sanitize(snippet)
        }
        return nil
    }

    static func sanitizeMessagePreservingNewlines(bodyText: String?, bodyHtml: String?, snippet: String?) -> String? {
        if let bodyText, !bodyText.isEmpty {
            return sanitizePreservingNewlines(bodyText)
        }
        if let bodyHtml, !bodyHtml.isEmpty, let htmlText = htmlToText(bodyHtml) {
            return sanitizePreservingNewlines(htmlText)
        }
        if let snippet, !snippet.isEmpty {
            return sanitizePreservingNewlines(snippet)
        }
        return nil
    }

    static func sanitize(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: "(https?://|www\\.)\\S+",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "(?i)utm_[a-z0-9_]+=\\S+",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "(?i)(gclid|fbclid|mc_eid|mc_cid)=\\S+",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sanitizePreservingNewlines(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(
            of: "(https?://|www\\.)\\S+",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "(?i)utm_[a-z0-9_]+=\\S+",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "(?i)(gclid|fbclid|mc_eid|mc_cid)=\\S+",
            with: "",
            options: .regularExpression
        )
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func htmlToText(_ html: String) -> String? {
        guard let data = html.data(using: .utf8) else { return nil }
        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]
        guard let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) else {
            return nil
        }
        let text = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
