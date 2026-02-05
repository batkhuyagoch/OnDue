import Foundation

protocol CandidateSelecting: Sendable {
    func isCandidate(_ message: MessageRecord) -> Bool
}

struct CandidateSelector: CandidateSelecting {
    private let preferences: FilterPreferencesStoring
    private let subjectKeywords = [
        "due", "invoice", "payment", "appointment", "renewal", "deadline", "statement", "policy"
    ]
    private let snippetKeywords = [
        "due by", "before", "deadline", "please submit", "action required"
    ]
    private let senderDomains = [
        "irs.gov", "ssa.gov", "medicare.gov",
        "geico.com", "allstate.com", "statefarm.com",
        "chase.com", "bankofamerica.com", "wellsfargo.com",
        "comcast.com", "verizon.com", "att.com"
    ]
    private let excludedLabels = [
        "category_promotions", "category_social"
    ]
    private let securityKeywords = [
        "password changed", "sign-in attempt", "signin attempt", "new sign-in",
        "security alert", "verification code", "one-time code", "otp"
    ]
    private let statementKeywords = [
        "statement available", "monthly statement", "account statement", "e-statement",
        "your statement", "statement ready", "billing statement"
    ]
    private let marketingKeywords = [
        "unsubscribe", "sale", "deal", "offer", "promo", "discount", "limited time"
    ]
    private let newsletterKeywords = [
        "newsletter", "announcement", "update", "digest", "roundup"
    ]
    private let shippingKeywords = [
        "shipped", "out for delivery", "delivered", "tracking", "shipment", "package"
    ]

    init(preferences: FilterPreferencesStoring) {
        self.preferences = preferences
    }

    func isCandidate(_ message: MessageRecord) -> Bool {
        let subject = message.subject.lowercased()
        let snippet = (message.snippet ?? "").lowercased()
        let senderDomain = message.fromDomain ?? ""
        let labels = (message.labelIds ?? "").lowercased()

        if excludedLabels.contains(where: { labels.contains($0) }) {
            return false
        }
        let combined = "\(subject) \(snippet)"
        if preferences.includeSecurityAlerts == false,
           securityKeywords.contains(where: { combined.contains($0) }) {
            return false
        }
        if preferences.includeStatements == false,
           statementKeywords.contains(where: { combined.contains($0) }) {
            return false
        }
        if preferences.includeMarketing == false,
           marketingKeywords.contains(where: { combined.contains($0) }) {
            return false
        }
        if preferences.includeNewsletters == false,
           newsletterKeywords.contains(where: { combined.contains($0) }) {
            return false
        }
        if preferences.includeShipping == false,
           shippingKeywords.contains(where: { combined.contains($0) }) {
            return false
        }
        if message.hasAttachments {
            return true
        }
        if subjectKeywords.contains(where: { subject.contains($0) }) {
            return true
        }
        if snippetKeywords.contains(where: { snippet.contains($0) }) {
            return true
        }
        if senderDomains.contains(where: { senderDomain.contains($0) }) {
            return true
        }
        return false
    }
}
