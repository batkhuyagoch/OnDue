import Foundation
import UIKit

struct ParsedEmail: Hashable {
    let subject: String
    let snippet: String
    let bodyText: String
    let sender: String
    let senderDomain: String?
    let hasAttachments: Bool
    let labelIds: [String]
    let normalizedText: String
    let actionableWindowText: String?
    let bodyHtml: String?
}

final class EmailParser {
    private static let numericEntityRegex = try? NSRegularExpression(pattern: "&#(x?[0-9A-Fa-f]+);")
    private static let namedEntityRegex = try? NSRegularExpression(pattern: "&([A-Za-z]{2,16});")

    func parse(message: MessageRecord) -> ParsedEmail {
        let subject = cleanExtractorArtifacts(message.subject)
        let snippet = cleanExtractorArtifacts(message.snippet ?? "")
        let rawBody: String
        if let bodyText = message.bodyText, !bodyText.isEmpty {
            rawBody = cleanExtractorArtifacts(bodyText)
        } else if let bodyHtml = message.bodyHtml, !bodyHtml.isEmpty {
            rawBody = cleanExtractorArtifacts(htmlToText(bodyHtml) ?? "")
        } else {
            rawBody = ""
        }
        let contextResult = boundedContextWithWindows(from: rawBody)
        let bodyText = contextResult.text
        let labels = (message.labelIds ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        let normalizedText = String(
            normalize("\(subject)\n\(snippet)\n\(bodyText)")
                .prefix(EmailContentBudget.normalizedTextCharsMax)
        )

        return ParsedEmail(
            subject: subject,
            snippet: snippet,
            bodyText: bodyText,
            sender: message.fromEmail,
            senderDomain: message.fromDomain,
            hasAttachments: message.hasAttachments,
            labelIds: labels,
            normalizedText: normalizedText,
            actionableWindowText: contextResult.actionableWindowText,
            bodyHtml: message.bodyHtml
        )
    }

    private func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let normalized = lowered.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func boundedContextWithWindows(from rawBody: String) -> (text: String, actionableWindowText: String?) {
        let precleanWasTruncated = rawBody.count > EmailContentBudget.htmlPrecleanCharsMax
        let preclean = String(rawBody.prefix(EmailContentBudget.htmlPrecleanCharsMax))
        let unquoted = stripQuotedText(preclean)
        let cleanedResult = removeCssArtifactLines(unquoted)
        let cleaned = cleanedResult.text
        if cleaned.count <= EmailContentBudget.parsedContextCharsMax {
#if DEBUG
            if precleanWasTruncated || cleanedResult.removedLineCount > 0 {
                Logger.info("email_context_debug body_truncated=\(precleanWasTruncated) css_artifact_lines_removed=\(cleanedResult.removedLineCount)")
            }
#endif
            return (cleaned.trimmingCharacters(in: .whitespacesAndNewlines), nil)
        }
        let windowed = extractActionableWindows(from: cleaned)
#if DEBUG
        Logger.info("email_context_debug body_truncated=\(precleanWasTruncated || cleaned.count > EmailContentBudget.parsedContextCharsMax) css_artifact_lines_removed=\(cleanedResult.removedLineCount)")
#endif
        let text = String(windowed.prefix(EmailContentBudget.parsedContextCharsMax))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, windowed.isEmpty ? nil : windowed)
    }

    private func stripQuotedText(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix(">")
        }
        let collapsed = filtered.joined(separator: "\n")
        let separators = ["\nOn ", "\n-----Original Message-----", "\n-- \n", "\nSent from my"]
        for separator in separators {
            if let range = collapsed.range(of: separator) {
                return String(collapsed[..<range.lowerBound])
            }
        }
        return collapsed
    }

    private func removeCssArtifactLines(_ text: String) -> (text: String, removedLineCount: Int) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var removedLineCount = 0
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty { return true }
            if trimmed.hasPrefix("@media") || trimmed.hasPrefix("@font-face") {
                removedLineCount += 1
                return false
            }
            if trimmed.contains("{") && trimmed.contains("}") {
                if trimmed.contains(".") || trimmed.contains("#") || trimmed.contains(":") {
                    removedLineCount += 1
                    return false
                }
            }
            if trimmed.hasPrefix(".") && trimmed.contains("{") {
                removedLineCount += 1
                return false
            }
            return true
        }
        return (filtered.joined(separator: "\n"), removedLineCount)
    }

    private func extractActionableWindows(from text: String) -> String {
        let lower = text.lowercased()
        let signals = [
            "due", "deadline", "by ", "before ", "action required",
            "verify", "verification", "payment", "invoice", "renew",
            "delivery", "package", "appointment", "meeting", "court", "irs"
        ]
        var ranges: [Range<String.Index>] = []
        for signal in signals {
            var searchStart = lower.startIndex
            while let found = lower.range(of: signal, range: searchStart..<lower.endIndex) {
                ranges.append(found)
                searchStart = found.upperBound
            }
        }
        ranges.append(contentsOf: dateLikeRanges(in: lower))
        guard !ranges.isEmpty else {
            return String(text.prefix(EmailContentBudget.parsedContextCharsMax))
        }

        let windows = boundedWindows(from: ranges, in: text)
        var selected: [String] = []
        var used = 0
        for window in windows.prefix(EmailContentBudget.maxContextWindows) {
            let chunk = text[window].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chunk.isEmpty else { continue }
            let separator = selected.isEmpty ? "" : "\n...\n"
            let candidateLength = used + separator.count + chunk.count
            if candidateLength > EmailContentBudget.parsedContextCharsMax {
                break
            }
            selected.append(String(chunk))
            used = candidateLength
        }
        if selected.isEmpty {
            return String(text.prefix(EmailContentBudget.parsedContextCharsMax))
        }
        return selected.joined(separator: "\n...\n")
    }

    private func dateLikeRanges(in text: String) -> [Range<String.Index>] {
        let patterns = [
            "\\b\\d{1,2}/\\d{1,2}(?:/\\d{2,4})?\\b",
            "\\b(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\\s+\\d{1,2}(?:,\\s*\\d{4})?\\b",
            "\\b(?:today|tomorrow|next\\s+week|next\\s+month)\\b"
        ]
        var ranges: [Range<String.Index>] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, options: [], range: nsRange) {
                if let range = Range(match.range, in: text) {
                    ranges.append(range)
                }
            }
        }
        return ranges
    }

    private func boundedWindows(from ranges: [Range<String.Index>], in text: String) -> [Range<String.Index>] {
        var windows: [Range<String.Index>] = ranges.map { range in
            let lowerOffset = max(0, text.distance(from: text.startIndex, to: range.lowerBound) - EmailContentBudget.windowRadiusChars)
            let upperOffset = min(text.count, text.distance(from: text.startIndex, to: range.upperBound) + EmailContentBudget.windowRadiusChars)
            let lower = text.index(text.startIndex, offsetBy: lowerOffset)
            let upper = text.index(text.startIndex, offsetBy: upperOffset)
            return lower..<upper
        }
        windows.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for window in windows {
            guard let last = merged.last else {
                merged.append(window)
                continue
            }
            if window.lowerBound <= last.upperBound {
                let mergedRange = last.lowerBound..<max(last.upperBound, window.upperBound)
                merged[merged.count - 1] = mergedRange
            } else {
                merged.append(window)
            }
        }
        return merged
    }

    private func htmlToText(_ html: String) -> String? {
        let decoded = decodeQuotedPrintable(in: html)
        guard let data = decoded.data(using: .utf8) else { return nil }
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

    private func decodeQuotedPrintable(in text: String) -> String {
        var decoded = text
        decoded = decoded.replacingOccurrences(of: "=\r\n", with: "")
        decoded = decoded.replacingOccurrences(of: "=\n", with: "")
        decoded = decoded.replacingOccurrences(of: "=3D", with: "=")
        decoded = decoded.replacingOccurrences(of: "=20", with: " ")
        return decoded
    }

    private func cleanExtractorArtifacts(_ text: String) -> String {
        var cleaned = decodeNumericHTMLEntities(in: text)
        cleaned = decodeNamedHTMLEntities(in: cleaned)
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

    private func decodeNumericHTMLEntities(in text: String) -> String {
        guard text.contains("&#"), let regex = Self.numericEntityRegex else {
            return text
        }
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
            let code = String(result[codeRange])
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

    private func decodeNamedHTMLEntities(in text: String) -> String {
        guard text.contains("&"), let regex = Self.namedEntityRegex else {
            return text
        }
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
            let replacement: String?
            switch name {
            case "nbsp", "ensp", "emsp", "thinsp", "hairsp", "numsp":
                replacement = " "
            case "shy", "zwnj", "zwj", "lrm", "rlm":
                replacement = ""
            case "amp":
                replacement = "&"
            case "lt":
                replacement = "<"
            case "gt":
                replacement = ">"
            case "quot":
                replacement = "\""
            case "apos":
                replacement = "'"
            default:
                replacement = nil
            }
            guard let replacement else { continue }
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }
}
