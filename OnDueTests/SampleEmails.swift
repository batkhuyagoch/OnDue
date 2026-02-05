import Foundation
@testable import OnDue

enum SampleEmails {
    static func paymentDue() -> ParsedEmail {
        makeEmail(
            subject: "Invoice #12345 due March 15",
            snippet: "Payment due by March 15 to avoid late fees.",
            bodyText: "Your invoice is attached. Payment due by March 15.",
            hasAttachments: true,
            labelIds: ["INBOX"]
        )
    }

    static func appointmentInvite() -> ParsedEmail {
        makeEmail(
            subject: "Appointment confirmation",
            snippet: "Your appointment is scheduled for Tuesday at 10am.",
            bodyText: "This is a calendar invite for your appointment.",
            hasAttachments: false,
            labelIds: ["INBOX"]
        )
    }

    static func marketingPromo() -> ParsedEmail {
        makeEmail(
            subject: "Limited time offer - 50% off",
            snippet: "Shop now and save. Unsubscribe anytime.",
            bodyText: "This is a promo email with a discount offer.",
            hasAttachments: false,
            labelIds: ["CATEGORY_PROMOTIONS"]
        )
    }

    static func documentRequest() -> ParsedEmail {
        makeEmail(
            subject: "Please sign and return",
            snippet: "Signature required for your document.",
            bodyText: "Please sign the attached document and return it.",
            hasAttachments: true,
            labelIds: ["INBOX"]
        )
    }

    private static func makeEmail(
        subject: String,
        snippet: String,
        bodyText: String,
        hasAttachments: Bool,
        labelIds: [String]
    ) -> ParsedEmail {
        let normalizedText = "\(subject)\n\(snippet)\n\(bodyText)"
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedEmail(
            subject: subject,
            snippet: snippet,
            bodyText: bodyText,
            sender: "billing@example.com",
            senderDomain: "example.com",
            hasAttachments: hasAttachments,
            labelIds: labelIds.map { $0.lowercased() },
            normalizedText: normalizedText
        )
    }
}
