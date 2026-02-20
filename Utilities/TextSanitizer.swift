import Foundation
import UIKit

enum EmailContentBudget {
    static let htmlPrecleanCharsMax = 200_000
    static let parsedContextCharsMax = 8_000
    static let normalizedTextCharsMax = 16_000
    static let decodeBytesMax = 2_000_000
    static let windowRadiusChars = 220
    static let maxContextWindows = 8
    static let detailPreviewCharsMax = 600
    static let detailFullSafeCharsMax = 32_000
}

enum TextSanitizer {
    struct DetailText {
        let preview: String
        let full: String
        let isTruncated: Bool
    }

    static func sanitizeDetailMessage(bodyText: String?, bodyHtml: String?, snippet: String?) -> DetailText? {
        guard let full = sanitizeMessagePreservingNewlines(bodyText: bodyText, bodyHtml: bodyHtml, snippet: snippet),
              !full.isEmpty else {
            return nil
        }

        let boundedFull = String(full.prefix(EmailContentBudget.detailFullSafeCharsMax))
        let isTruncated = full.count > EmailContentBudget.detailPreviewCharsMax
        let preview: String
        if isTruncated {
            let truncated = String(boundedFull.prefix(EmailContentBudget.detailPreviewCharsMax))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            preview = truncated + "…"
        } else {
            preview = boundedFull
        }
        return DetailText(preview: preview, full: boundedFull, isTruncated: isTruncated)
    }

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
