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

    static func actionRequiredWithUnsubscribe() -> ParsedEmail {
        makeEmail(
            subject: "Please confirm your account details",
            snippet: "Action required: confirm your details by Friday.",
            bodyText: "Please confirm your details by Friday. You can unsubscribe at any time.",
            hasAttachments: false,
            labelIds: ["INBOX"]
        )
    }

    static func securityAlert() -> ParsedEmail {
        makeEmail(
            subject: "Security alert: new sign-in",
            snippet: "New sign-in detected. If this wasn’t you, reset your password.",
            bodyText: "Security alert: new sign-in from a new device.",
            sender: "no.reply@bank.com",
            senderDomain: "bank.com",
            hasAttachments: false,
            labelIds: ["INBOX"]
        )
    }

    static func receiptEmail() -> ParsedEmail {
        makeEmail(
            subject: "Your receipt from Store",
            snippet: "Thanks for your purchase. Receipt attached.",
            bodyText: "Receipt for your purchase. Total paid.",
            hasAttachments: false,
            labelIds: ["INBOX"]
        )
    }

    static func dateOnlyInfo() -> ParsedEmail {
        makeEmail(
            subject: "Event update for March 15",
            snippet: "Here’s the schedule for March 15.",
            bodyText: "Schedule for March 15 is now available.",
            hasAttachments: false,
            labelIds: ["INBOX"]
        )
    }

    static func promoUrgency() -> ParsedEmail {
        makeEmail(
            subject: "Final hours: 30% off",
            snippet: "Act now to save. Unsubscribe anytime.",
            bodyText: "Limited time offer. Act now.",
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

    static func uscisReceiptNotice() -> ParsedEmail {
        makeEmail(
            subject: "USCIS Receipt Notice (I-797C) - Case Was Received",
            snippet: "Your case status has been updated.",
            bodyText: "This is a Notice of Action (I-797C). Case was received.",
            sender: "noreply@uscis.gov",
            senderDomain: "uscis.gov",
            hasAttachments: false,
            labelIds: ["INBOX"]
        )
    }

    static func uscisRFE() -> ParsedEmail {
        makeEmail(
            subject: "USCIS Request for Evidence",
            snippet: "Response due by March 30.",
            bodyText: "This is a Request for Evidence (RFE). Respond by March 30.",
            sender: "updates@uscis.gov",
            senderDomain: "uscis.gov",
            hasAttachments: true,
            labelIds: ["INBOX"]
        )
    }

    static func uscisBiometrics() -> ParsedEmail {
        makeEmail(
            subject: "Biometrics Appointment Notice",
            snippet: "Your ASC appointment is scheduled.",
            bodyText: "Biometric services appointment at the Application Support Center.",
            sender: "appointments@uscis.gov",
            senderDomain: "uscis.gov",
            hasAttachments: false,
            labelIds: ["INBOX"]
        )
    }

    static func courtNotice() -> ParsedEmail {
        makeEmail(
            subject: "Court Notice: Hearing Date",
            snippet: "You are ordered to appear in court.",
            bodyText: "This is a court notice. Hearing date set for April 5.",
            sender: "clerk@uscourts.gov",
            senderDomain: "uscourts.gov",
            hasAttachments: false,
            labelIds: ["INBOX"]
        )
    }

    static func irsNotice() -> ParsedEmail {
        makeEmail(
            subject: "IRS Notice CP2000 - Balance Due",
            snippet: "Balance due to the IRS.",
            bodyText: "This is an IRS notice. Payment due to the IRS.",
            sender: "notices@irs.gov",
            senderDomain: "irs.gov",
            hasAttachments: false,
            labelIds: ["INBOX"]
        )
    }

    static func stateAgencyNotice() -> ParsedEmail {
        makeEmail(
            subject: "State Agency Notice: Compliance Required",
            snippet: "Action required by April 10.",
            bodyText: "This is an official notice from a state agency. Respond by April 10.",
            sender: "alerts@dps.state.tx.us",
            senderDomain: "dps.state.tx.us",
            hasAttachments: false,
            labelIds: ["INBOX"]
        )
    }

    private static func makeEmail(
        subject: String,
        snippet: String,
        bodyText: String,
        sender: String = "billing@example.com",
        senderDomain: String? = "example.com",
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
            sender: sender,
            senderDomain: senderDomain,
            hasAttachments: hasAttachments,
            labelIds: labelIds.map { $0.lowercased() },
            normalizedText: normalizedText
        )
    }
}
