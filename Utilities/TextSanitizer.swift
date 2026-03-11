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
    private static let looseNumericEntityRegex = try? NSRegularExpression(
        pattern: "&\\s*#\\s*([xX]?[0-9A-Fa-f\\s]+?)\\s*;"
    )
    private static let namedEntityRegex = try? NSRegularExpression(
        pattern: "&\\s*([A-Za-z]{2,16})\\s*;"
    )

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
            let previewBudget = max(0, EmailContentBudget.detailPreviewCharsMax - 1)
            let truncated = String(boundedFull.prefix(previewBudget))
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
        var cleaned = stripExtractorArtifacts(text)
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
        var cleaned = stripExtractorArtifacts(text)
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
        cleaned = cleaned.replacingOccurrences(
            of: "[^\\S\\r\\n]+",
            with: " ",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "\\n{3,}",
            with: "\n\n",
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

    private static func stripExtractorArtifacts(_ text: String) -> String {
        var cleaned = decodeLooseNumericEntities(in: text)
        cleaned = decodeNamedEntities(in: cleaned)
        cleaned = cleaned.replacingOccurrences(of: "\u{00A0}", with: " ")

        var normalizedScalars: [UnicodeScalar] = []
        normalizedScalars.reserveCapacity(cleaned.unicodeScalars.count)

        for scalar in cleaned.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                normalizedScalars.append(scalar)
                continue
            }

            if scalar.properties.isWhitespace {
                normalizedScalars.append(" ")
                continue
            }

            let category = scalar.properties.generalCategory
            if category == .format || category == .control {
                continue
            }

            normalizedScalars.append(scalar)
        }

        return String(String.UnicodeScalarView(normalizedScalars))
    }

    private static func decodeLooseNumericEntities(in text: String) -> String {
        guard text.contains("&"), let regex = looseNumericEntityRegex else { return text }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let codeRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            var code = String(result[codeRange])
            code = code.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)

            let scalarValue: UInt32?
            if code.hasPrefix("x") || code.hasPrefix("X") {
                scalarValue = UInt32(code.dropFirst(), radix: 16)
            } else {
                scalarValue = UInt32(code, radix: 10)
            }
            guard let value = scalarValue, let scalar = UnicodeScalar(value) else { continue }
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }
        return result
    }

    private static func decodeNamedEntities(in text: String) -> String {
        guard text.contains("&"), let regex = namedEntityRegex else { return text }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: nsRange)
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard match.numberOfRanges >= 2,
                  let fullRange = Range(match.range(at: 0), in: result),
                  let nameRange = Range(match.range(at: 1), in: result) else {
                continue
            }
            let name = String(result[nameRange]).lowercased()
            guard let replacement = replacementForNamedEntity(name) else { continue }
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    private static func replacementForNamedEntity(_ name: String) -> String? {
        switch name {
        case "nbsp": return " "
        case "ensp": return " "
        case "emsp": return " "
        case "thinsp": return " "
        case "hairsp": return " "
        case "numsp": return " "
        case "shy": return ""
        case "zwnj": return ""
        case "zwj": return ""
        case "lrm": return ""
        case "rlm": return ""
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        default: return nil
        }
    }
}
