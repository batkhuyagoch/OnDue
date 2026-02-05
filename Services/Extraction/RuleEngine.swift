import Foundation
@preconcurrency import Combine

enum SignalType: String, Hashable {
    case keyword
    case sender
    case label
    case attachment
    case date
}

struct RuleMatch: Hashable {
    let id: String
    let weight: Double
    let reason: String
    let signalType: SignalType
    let category: ObligationCategory?
}

struct RuleAssessment {
    let score: Double
    let category: ObligationCategory
    let risk: ObligationRisk
    let confidence: Double
    let evidenceQuote: String
    let deadline: Date?
    let matchedRuleIds: [String]
    let matchedSignalTypes: [SignalType]
    let matchedReasons: [String]
}

final class RuleEngine {
    private let preferences: FilterPreferencesStoring
    private let threshold: Double = 1.2
    private let borderlineMin: Double = 0.8

    init(preferences: FilterPreferencesStoring) {
        self.preferences = preferences
    }

    func evaluate(email: ParsedEmail, weightMultipliers: [String: Double] = [:]) -> RuleAssessment? {
        let assessment = assess(email: email, weightMultipliers: weightMultipliers)
        return isAccepted(assessment) ? assessment : nil
    }

    func assess(email: ParsedEmail, weightMultipliers: [String: Double] = [:]) -> RuleAssessment {
        var score = 0.0
        var matches: [RuleMatch] = []
        var categoryScores: [ObligationCategory: Double] = [:]

        for signal in signals where signal.matches(email) {
            let multiplier = weightMultipliers[signal.id] ?? 1.0
            let adjustedWeight = signal.weight * multiplier
            score += adjustedWeight
            matches.append(
                RuleMatch(
                    id: signal.id,
                    weight: adjustedWeight,
                    reason: signal.reason,
                    signalType: signal.signalType,
                    category: signal.category
                )
            )
            if let category = signal.category {
                categoryScores[category, default: 0.0] += adjustedWeight
            }
        }

        let deadline = DateParsing.parseDate(from: email.normalizedText)
        if deadline != nil {
            score += 0.5
            categoryScores[.deadline, default: 0.0] += 0.5
            matches.append(
                RuleMatch(
                    id: "date_detected",
                    weight: 0.5,
                    reason: "Detected a date",
                    signalType: .date,
                    category: .deadline
                )
            )
        }

        let preferredCategory = categoryScores.max(by: { $0.value < $1.value })?.key ?? .other
        let category: ObligationCategory
        if preferredCategory == .deadline,
           let paymentScore = categoryScores[.payment],
           let deadlineScore = categoryScores[.deadline],
           paymentScore >= (deadlineScore - 0.3) {
            category = .payment
        } else {
            category = preferredCategory
        }
        let risk: ObligationRisk
        if score >= 1.8 {
            risk = .high
        } else if score >= 1.4 {
            risk = .medium
        } else {
            risk = .low
        }

        let confidence = min(1.0, max(0.3, score / 2.0))
        let evidenceQuote = makeEvidenceQuote(from: email)

        return RuleAssessment(
            score: score,
            category: category,
            risk: risk,
            confidence: confidence,
            evidenceQuote: evidenceQuote,
            deadline: deadline,
            matchedRuleIds: matches.map(\.id),
            matchedSignalTypes: matches.map(\.signalType),
            matchedReasons: matches.map(\.reason)
        )
    }

    func isBorderline(_ assessment: RuleAssessment) -> Bool {
        assessment.score >= borderlineMin && assessment.score < threshold
    }

    func isAccepted(_ assessment: RuleAssessment) -> Bool {
        assessment.score >= threshold
    }

    private func makeEvidenceQuote(from email: ParsedEmail) -> String {
        let snippet = email.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty {
            return String(snippet.prefix(140))
        }
        return String(email.subject.prefix(140))
    }

    private var signals: [Signal] {
        var base: [Signal] = [
            Signal(
                id: "deadline_keyword",
                weight: 0.9,
                reason: "Contains a deadline keyword",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "due", "deadline", "by end of day", "by eod", "expires on",
                        "submit by", "respond by", "payment due"
                    ])
                }
            ),
            Signal(
                id: "payment_keyword",
                weight: 1.1,
                reason: "Payment or billing language",
                signalType: .keyword,
                category: .payment,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "invoice", "bill", "payment", "amount due", "statement", "autopay"
                    ])
                }
            ),
            Signal(
                id: "document_keyword",
                weight: 0.7,
                reason: "Document or signature request",
                signalType: .keyword,
                category: .document,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "document", "signature", "sign", "upload", "attach", "form", "w-2", "1099"
                    ])
                }
            ),
            Signal(
                id: "policy_keyword",
                weight: 0.7,
                reason: "Policy or renewal language",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "policy", "renewal", "renew", "coverage", "insurance"
                    ])
                }
            ),
            Signal(
                id: "travel_keyword",
                weight: 1.0,
                reason: "Travel itinerary or booking",
                signalType: .keyword,
                category: .appointment,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "itinerary", "booking", "reservation", "flight", "hotel", "check-in",
                        "appointment", "scheduled", "calendar invite", "meeting"
                    ])
                }
            ),
            Signal(
                id: "request_keyword",
                weight: 0.6,
                reason: "Explicit request language",
                signalType: .keyword,
                category: .request,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "please", "need you to", "action required", "required action", "please confirm"
                    ])
                }
            ),
            Signal(
                id: "attachment_present",
                weight: 0.4,
                reason: "Attachment included",
                signalType: .attachment,
                category: nil,
                matches: { $0.hasAttachments }
            ),
            Signal(
                id: "promo_label",
                weight: -1.0,
                reason: "Promotions or social label",
                signalType: .label,
                category: nil,
                matches: { email in
                    email.labelIds.contains(where: { $0.contains("category_promotions") || $0.contains("category_social") })
                }
            ),
            Signal(
                id: "promo_keywords",
                weight: -0.8,
                reason: "Marketing language",
                signalType: .keyword,
                category: nil,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "unsubscribe", "sale", "deal", "offer", "promo", "discount",
                        "newsletter", "limited time", "shop now", "coupon"
                    ])
                }
            )
        ]

        if preferences.includeSecurityAlerts == false {
            base.append(
                Signal(
                    id: "security_alerts",
                    weight: -2.0,
                    reason: "Security alert",
                    signalType: .keyword,
                    category: nil,
                    matches: { email in
                        containsAny(email.normalizedText, [
                            "password changed", "sign-in attempt", "signin attempt", "new sign-in",
                            "security alert", "verification code", "one-time code", "otp"
                        ])
                    }
                )
            )
        }

        if preferences.includeStatements == false {
            base.append(
                Signal(
                    id: "statements",
                    weight: -1.6,
                    reason: "Statement",
                    signalType: .keyword,
                    category: nil,
                    matches: { email in
                        containsAny(email.normalizedText, [
                            "statement available", "monthly statement", "account statement",
                            "e-statement", "statement ready", "billing statement"
                        ])
                    }
                )
            )
        }

        if preferences.includeMarketing == false {
            base.append(
                Signal(
                    id: "marketing",
                    weight: -1.6,
                    reason: "Marketing",
                    signalType: .keyword,
                    category: nil,
                    matches: { email in
                        containsAny(email.normalizedText, [
                            "unsubscribe", "sale", "deal", "offer", "promo", "discount", "limited time"
                        ])
                    }
                )
            )
        }

        if preferences.includeNewsletters == false {
            base.append(
                Signal(
                    id: "newsletters",
                    weight: -1.2,
                    reason: "Newsletter",
                    signalType: .keyword,
                    category: nil,
                    matches: { email in
                        containsAny(email.normalizedText, [
                            "newsletter", "announcement", "update", "digest", "roundup"
                        ])
                    }
                )
            )
        }

        if preferences.includeShipping == false {
            base.append(
                Signal(
                    id: "shipping_updates",
                    weight: -1.4,
                    reason: "Shipping update",
                    signalType: .keyword,
                    category: nil,
                    matches: { email in
                        containsAny(email.normalizedText, [
                            "shipped", "out for delivery", "delivered", "tracking", "shipment", "package"
                        ])
                    }
                )
            )
        }

        return base
    }
}

private struct Signal {
    let id: String
    let weight: Double
    let reason: String
    let signalType: SignalType
    let category: ObligationCategory?
    let matches: (ParsedEmail) -> Bool
}

private func containsAny(_ text: String, _ keywords: [String]) -> Bool {
    keywords.contains(where: { text.contains($0) })
}
