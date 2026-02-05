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
}

final class EmailParser {
    private let maxBodyLength = 12_000

    func parse(message: MessageRecord) -> ParsedEmail {
        let subject = message.subject
        let snippet = message.snippet ?? ""
        let rawBody: String
        if let bodyText = message.bodyText, !bodyText.isEmpty {
            rawBody = bodyText
        } else if let bodyHtml = message.bodyHtml, !bodyHtml.isEmpty {
            rawBody = htmlToText(bodyHtml) ?? ""
        } else {
            rawBody = ""
        }
        let bodyText = String(stripQuotedText(rawBody).prefix(maxBodyLength))
        let labels = (message.labelIds ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        let normalizedText = normalize("\(subject)\n\(snippet)\n\(bodyText)")

        return ParsedEmail(
            subject: subject,
            snippet: snippet,
            bodyText: bodyText,
            sender: message.fromEmail,
            senderDomain: message.fromDomain,
            hasAttachments: message.hasAttachments,
            labelIds: labels,
            normalizedText: normalizedText
        )
    }

    private func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        let normalized = lowered.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
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
}
