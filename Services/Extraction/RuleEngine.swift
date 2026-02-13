import Foundation
@preconcurrency import Combine

enum SignalType: String, Hashable {
    case keyword
    case sender
    case label
    case attachment
    case date
}

enum ObligationDecision: String, Codable {
    case accept
    case needsReview
    case reject
}

enum HypothesisConfidence: String, Codable {
    case high
    case medium
    case low
}

enum HypothesisOutcome: String, Codable {
    case accepted
    case blocked
    case needsReview
}

enum ObligationHypothesis: String, CaseIterable, Codable {
    case userActionRequired
    case deadlineImplied
    case waitingOnThirdParty
    case legalOrCompliance
    case marketingNoise
}

struct HypothesisDefinition {
    let id: ObligationHypothesis
    let requiresAny: [String]
    let requiresAll: [String]
    let boosts: [String]
    let blocks: [String]
    let lowWithoutBoost: Bool
}

struct HypothesisEvaluation {
    let hypothesis: ObligationHypothesis
    let confidence: HypothesisConfidence
    let reasons: [String]
    let matchedSignals: [String]
}

struct HypothesisEvaluationDebug: Codable {
    let emailId: String
    let hypothesisId: ObligationHypothesis
    let requiredEvidence: [String: Bool]
    let boostEvidence: [String]
    let blockers: [String]
    let confidence: HypothesisConfidence
    let outcome: HypothesisOutcome
}

struct RuleMatch: Hashable {
    let id: String
    let weight: Double
    let reason: String
    let signalType: SignalType
    let category: ObligationCategory?
}

struct RuleAssessment {
    let decision: ObligationDecision
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
    private let yearScanThreshold: Double = 2.6
    private let yearScanHardSignalIds: Set<String> = [
        "past_due",
        "final_notice",
        "collections",
        "coverage_lapsed",
        "policy_canceled",
        "license_suspended",
        "tax_notice",
        "court_notice",
        "benefits_deadline_missed",
        "identity_verification",
        "legal_sender_gov_allowlist",
        "legal_sender_uscis",
        "legal_sender_state",
        "legal_sender_ssa",
        "legal_sender_irs",
        "legal_sender_courts",
        "uscis_receipt_notice",
        "uscis_rfe",
        "uscis_biometrics",
        "uscis_interview",
        "immigration_deadline",
        "irs_notice",
        "jury_duty",
        "court_summons",
        "passport_renewal",
        "ssa_notice"
    ]

    init(preferences: FilterPreferencesStoring) {
        self.preferences = preferences
    }

    func evaluate(email: ParsedEmail, weightMultipliers: [String: Double] = [:]) -> RuleAssessment? {
        let assessment = assess(email: email, weightMultipliers: weightMultipliers)
        return isAccepted(assessment) ? assessment : nil
    }

    func assess(email: ParsedEmail, weightMultipliers: [String: Double] = [:]) -> RuleAssessment {
        buildHypothesisAssessment(email: email)
    }

    func evaluateYearScan(email: ParsedEmail) -> RuleAssessment? {
        let assessment = buildAssessment(
            email: email,
            signals: yearScanSignals,
            includeDate: false,
            weightMultipliers: [:]
        )
        guard assessment.score >= yearScanThreshold else { return nil }
        guard assessment.matchedRuleIds.contains(where: { yearScanHardSignalIds.contains($0) }) else { return nil }
        return assessment
    }

    func isBorderline(_ assessment: RuleAssessment) -> Bool {
        assessment.decision == .needsReview
    }

    func isAccepted(_ assessment: RuleAssessment) -> Bool {
        assessment.decision == .accept
    }

    private func makeEvidenceQuote(from email: ParsedEmail) -> String {
        let snippet = email.snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if !snippet.isEmpty {
            return String(snippet.prefix(140))
        }
        return String(email.subject.prefix(140))
    }

    private func buildAssessment(
        email: ParsedEmail,
        signals: [Signal],
        includeDate: Bool,
        weightMultipliers: [String: Double]
    ) -> RuleAssessment {
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

        var deadline: Date?
        if includeDate {
            deadline = DateParsing.parseDate(from: email.normalizedText)
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
            decision: .accept,
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

    private func buildHypothesisAssessment(email: ParsedEmail) -> RuleAssessment {
        let matchedSignals = matchSignals(email: email, includeDate: true)
        let matchedIds = Set(matchedSignals.map(\.id))
        let matchedSignalTypes = Array(Set(matchedSignals.map(\.signalType)))

        let globalBlockers = matchedSignals.filter { globalBlockerSignalIds.contains($0.id) }
        if !globalBlockers.isEmpty {
            let reasons = uniqueReasons(from: globalBlockers)
            return RuleAssessment(
                decision: .reject,
                score: 0.0,
                category: .other,
                risk: .low,
                confidence: 0.3,
                evidenceQuote: makeEvidenceQuote(from: email),
                deadline: DateParsing.parseDate(from: email.normalizedText),
                matchedRuleIds: [ObligationHypothesis.marketingNoise.rawValue],
                matchedSignalTypes: matchedSignalTypes,
                matchedReasons: reasons
            )
        }

        let evaluations = evaluateHypotheses(matchedIds: matchedIds, matchedSignals: matchedSignals)
        emitHypothesisDebug(
            emailId: email.subject,
            matchedIds: matchedIds,
            matchedSignals: matchedSignals,
            evaluations: evaluations
        )
        let decision = decideOutcome(evaluations)
        let confidence = confidenceValue(for: decision, evaluations: evaluations)
        let reasons = reasonsForOutcome(evaluations)
        let category = determineCategory(from: matchedSignals, evaluations: evaluations)
        let risk = determineRisk(evaluations: evaluations)
        let deadline = DateParsing.parseDate(from: email.normalizedText)

        return RuleAssessment(
            decision: decision,
            score: confidence,
            category: category,
            risk: risk,
            confidence: confidence,
            evidenceQuote: makeEvidenceQuote(from: email),
            deadline: deadline,
            matchedRuleIds: evaluations.map { $0.hypothesis.rawValue },
            matchedSignalTypes: matchedSignalTypes,
            matchedReasons: reasons
        )
    }

    private struct MatchedSignal {
        let id: String
        let reason: String
        let signalType: SignalType
        let category: ObligationCategory?
    }

    private func matchSignals(email: ParsedEmail, includeDate: Bool) -> [MatchedSignal] {
        var matched: [MatchedSignal] = []
        for signal in signals where signal.matches(email) {
            matched.append(
                MatchedSignal(
                    id: signal.id,
                    reason: signal.reason,
                    signalType: signal.signalType,
                    category: signal.category
                )
            )
        }
        if includeDate, DateParsing.parseDate(from: email.normalizedText) != nil {
            matched.append(
                MatchedSignal(
                    id: "date_detected",
                    reason: "Includes a date",
                    signalType: .date,
                    category: .deadline
                )
            )
        }
        return matched
    }

    private var hypothesisDefinitions: [HypothesisDefinition] {
        [
            HypothesisDefinition(
                id: .userActionRequired,
                requiresAny: ["request_keyword", "document_keyword", "payment_keyword"],
                requiresAll: [],
                boosts: ["direct_address", "attachment_present", "known_sender"],
                blocks: [],
                lowWithoutBoost: false
            ),
            HypothesisDefinition(
                id: .deadlineImplied,
                requiresAny: ["deadline_keyword", "policy_keyword", "document_expires_soon"],
                requiresAll: ["date_detected"],
                boosts: ["deadline_keyword", "date_detected"],
                blocks: [],
                lowWithoutBoost: true
            ),
            HypothesisDefinition(
                id: .waitingOnThirdParty,
                requiresAny: ["waiting_on_phrase"],
                requiresAll: [],
                boosts: [],
                blocks: [],
                lowWithoutBoost: true
            ),
            HypothesisDefinition(
                id: .legalOrCompliance,
                requiresAny: [
                    "legal_sender_gov_allowlist",
                    "legal_sender_uscis",
                    "legal_sender_state",
                    "legal_sender_ssa",
                    "legal_sender_irs",
                    "legal_sender_courts",
                    "tax_notice",
                    "court_notice",
                    "irs_notice",
                    "jury_duty",
                    "court_summons",
                    "passport_renewal"
                ],
                requiresAll: [],
                boosts: ["deadline_keyword", "date_detected"],
                blocks: [],
                lowWithoutBoost: false
            ),
            HypothesisDefinition(
                id: .marketingNoise,
                requiresAny: [
                    "promo_label",
                    "promo_keywords",
                    "marketing_language",
                    "promotional_label",
                    "newsletter",
                    "newsletters",
                    "unsubscribe_footer",
                    "bulk_sender_hint"
                ],
                requiresAll: [],
                boosts: [],
                blocks: [],
                lowWithoutBoost: true
            )
        ]
    }

    private var globalBlockerSignalIds: Set<String> {
        var blockers: Set<String> = [
            "unsubscribe_footer",
            "bulk_sender_hint",
            "promo_label",
            "promo_keywords",
            "marketing_language",
            "promotional_label",
            "receipt_statement",
            "security_alert",
            "informational_update",
            "promo_urgency"
        ]
        if preferences.includeMarketing == false {
            blockers.insert("marketing")
        }
        if preferences.includeNewsletters == false {
            blockers.insert("newsletter")
            blockers.insert("newsletters")
        }
        return blockers
    }

    private func evaluateHypotheses(
        matchedIds: Set<String>,
        matchedSignals: [MatchedSignal]
    ) -> [HypothesisEvaluation] {
        hypothesisDefinitions.compactMap { definition in
            if !definition.requiresAll.allSatisfy({ matchedIds.contains($0) }) {
                return nil
            }
            if !definition.requiresAny.isEmpty, !definition.requiresAny.contains(where: { matchedIds.contains($0) }) {
                return nil
            }
            if definition.blocks.contains(where: { matchedIds.contains($0) }) {
                return nil
            }

            let boostHit = definition.boosts.contains(where: { matchedIds.contains($0) })
            let confidence: HypothesisConfidence
            if boostHit {
                confidence = .high
            } else if definition.lowWithoutBoost {
                confidence = .low
            } else {
                confidence = .medium
            }

            let reasonSignals = matchedSignals.filter { signal in
                definition.requiresAny.contains(signal.id) ||
                definition.requiresAll.contains(signal.id) ||
                definition.boosts.contains(signal.id)
            }
            let reasons = uniqueReasons(from: reasonSignals)
            let matched = reasonSignals.map(\.id)

            return HypothesisEvaluation(
                hypothesis: definition.id,
                confidence: confidence,
                reasons: reasons,
                matchedSignals: matched
            )
        }
    }

    private func emitHypothesisDebug(
        emailId: String,
        matchedIds: Set<String>,
        matchedSignals: [MatchedSignal],
        evaluations: [HypothesisEvaluation]
    ) {
#if DEBUG
        let byHypothesis = Dictionary(uniqueKeysWithValues: evaluations.map { ($0.hypothesis, $0) })
        for definition in hypothesisDefinitions {
            let requiredAll = definition.requiresAll.reduce(into: [String: Bool]()) { result, id in
                result[id] = matchedIds.contains(id)
            }
            let requiredAny = definition.requiresAny.reduce(into: [String: Bool]()) { result, id in
                result[id] = matchedIds.contains(id)
            }
            var required: [String: Bool] = requiredAll
            for (key, value) in requiredAny {
                required[key] = value
            }

            let boosts = definition.boosts.filter { matchedIds.contains($0) }
            let blockers = definition.blocks.filter { matchedIds.contains($0) }

            let evaluation = byHypothesis[definition.id]
            let outcome: HypothesisOutcome
            if blockers.count > 0 {
                outcome = .blocked
            } else if evaluation?.confidence == .high || evaluation?.confidence == .medium {
                outcome = .accepted
            } else {
                outcome = .needsReview
            }

            let debug = HypothesisEvaluationDebug(
                emailId: emailId,
                hypothesisId: definition.id,
                requiredEvidence: required,
                boostEvidence: boosts,
                blockers: blockers,
                confidence: evaluation?.confidence ?? .low,
                outcome: outcome
            )

            if let encoded = try? JSONEncoder().encode(debug),
               let json = String(data: encoded, encoding: .utf8) {
                Logger.info("HypothesisDebug \(json)")
            }
        }
#endif
    }

    private func decideOutcome(_ evaluations: [HypothesisEvaluation]) -> ObligationDecision {
        let byHypothesis = Dictionary(uniqueKeysWithValues: evaluations.map { ($0.hypothesis, $0) })
        let userAction = byHypothesis[.userActionRequired]
        let deadline = byHypothesis[.deadlineImplied]
        let waiting = byHypothesis[.waitingOnThirdParty]
        let legal = byHypothesis[.legalOrCompliance]

        if let legal, legal.confidence != .low {
            return .accept
        }

        if userAction?.confidence == .high,
           deadline?.confidence == .high || deadline?.confidence == .medium {
            return .accept
        }

        if waiting?.confidence == .high {
            return .accept
        }

        if userAction?.confidence == .high {
            return .needsReview
        }

        if userAction?.confidence == .medium,
           deadline?.confidence == .high || deadline?.confidence == .medium {
            return .needsReview
        }

        if deadline?.confidence == .high {
            return .needsReview
        }

        return .reject
    }

    private func confidenceValue(for decision: ObligationDecision, evaluations: [HypothesisEvaluation]) -> Double {
        let maxConfidence = evaluations.map(\.confidence).sorted(by: { lhs, rhs in
            confidenceRank(lhs) > confidenceRank(rhs)
        }).first

        switch decision {
        case .accept:
            return confidenceValue(for: maxConfidence ?? .medium)
        case .needsReview:
            return confidenceValue(for: .low)
        case .reject:
            return 0.3
        }
    }

    private func confidenceValue(for confidence: HypothesisConfidence) -> Double {
        switch confidence {
        case .high: return 0.85
        case .medium: return 0.7
        case .low: return 0.55
        }
    }

    func confidenceLabel(for email: ParsedEmail) -> String {
        let matchedSignals = matchSignals(email: email, includeDate: true)
        let matchedIds = Set(matchedSignals.map(\.id))
        let evaluations = evaluateHypotheses(matchedIds: matchedIds, matchedSignals: matchedSignals)
        let top = evaluations.map(\.confidence).sorted(by: { confidenceRank($0) > confidenceRank($1) }).first
        switch top ?? .low {
        case .high: return "high"
        case .medium: return "medium"
        case .low: return "low"
        }
    }

    private func confidenceRank(_ confidence: HypothesisConfidence) -> Int {
        switch confidence {
        case .high: return 3
        case .medium: return 2
        case .low: return 1
        }
    }

    private func reasonsForOutcome(_ evaluations: [HypothesisEvaluation]) -> [String] {
        let prioritized = evaluations
            .sorted { confidenceRank($0.confidence) > confidenceRank($1.confidence) }
        let reasons = prioritized.flatMap(\.reasons)
        return Array(Set(reasons))
    }

    private func determineCategory(
        from matchedSignals: [MatchedSignal],
        evaluations: [HypothesisEvaluation]
    ) -> ObligationCategory {
        if evaluations.contains(where: { $0.hypothesis == .waitingOnThirdParty }) {
            return .followUp
        }

        let categories = matchedSignals.compactMap(\.category)
        if categories.contains(.payment) { return .payment }
        if categories.contains(.document) { return .document }
        if categories.contains(.appointment) { return .appointment }
        if categories.contains(.deadline) { return .deadline }
        if categories.contains(.request) { return .request }
        return .other
    }

    private func determineRisk(evaluations: [HypothesisEvaluation]) -> ObligationRisk {
        let legal = evaluations.first { $0.hypothesis == .legalOrCompliance }
        if legal?.confidence == .high || legal?.confidence == .medium {
            return .high
        }
        let deadline = evaluations.first { $0.hypothesis == .deadlineImplied }
        if deadline?.confidence == .high {
            return .medium
        }
        let action = evaluations.first { $0.hypothesis == .userActionRequired }
        if action?.confidence == .high {
            return .medium
        }
        return .low
    }

    private func uniqueReasons(from signals: [MatchedSignal]) -> [String] {
        var seen = Set<String>()
        var reasons: [String] = []
        for signal in signals {
            let reason = signal.reason
            guard !seen.contains(reason) else { continue }
            seen.insert(reason)
            reasons.append(reason)
        }
        return reasons
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
                id: "waiting_on_phrase",
                weight: 0.4,
                reason: "Waiting on someone else",
                signalType: .keyword,
                category: .followUp,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "waiting on", "awaiting", "pending approval", "we'll get back", "we will get back",
                        "once approved", "once reviewed"
                    ])
                }
            ),
            Signal(
                id: "direct_address",
                weight: 0.4,
                reason: "Directly addressed to you",
                signalType: .keyword,
                category: nil,
                matches: { email in
                    containsAny(email.normalizedText, ["hi ", "hello ", "dear "])
                }
            ),
            Signal(
                id: "known_sender",
                weight: 0.4,
                reason: "Known sender domain",
                signalType: .sender,
                category: nil,
                matches: { email in
                    guard let domain = email.senderDomain?.lowercased() else { return false }
                    let freeDomains = ["gmail.com", "yahoo.com", "outlook.com", "hotmail.com", "icloud.com"]
                    return !freeDomains.contains(domain)
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
                id: "unsubscribe_footer",
                weight: -2.0,
                reason: "Unsubscribe or preference footer",
                signalType: .keyword,
                category: nil,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "unsubscribe", "manage preferences", "email preferences",
                        "opt out", "update your preferences"
                    ])
                }
            ),
            Signal(
                id: "bulk_sender_hint",
                weight: -1.6,
                reason: "Bulk or mailing list",
                signalType: .keyword,
                category: nil,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "list-unsubscribe", "mailing list", "subscription preferences"
                    ])
                }
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

        base.append(contentsOf: [
            Signal(
                id: "receipt_statement",
                weight: -2.0,
                reason: "Receipt or statement",
                signalType: .keyword,
                category: nil,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "receipt", "statement", "purchase confirmation", "order confirmation",
                        "thanks for your purchase", "transaction summary", "invoice paid"
                    ])
                }
            ),
            Signal(
                id: "security_alert",
                weight: -2.0,
                reason: "Security alert or login code",
                signalType: .keyword,
                category: nil,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "security alert", "new sign-in", "new login", "login code",
                        "verification code", "one-time code", "otp", "signed in from"
                    ])
                }
            ),
            Signal(
                id: "informational_update",
                weight: -1.8,
                reason: "Informational update or newsletter",
                signalType: .keyword,
                category: nil,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "newsletter", "update", "news", "snack", "digest", "weekly roundup",
                        "this week in", "latest news"
                    ])
                }
            ),
            Signal(
                id: "promo_urgency",
                weight: -2.0,
                reason: "Promo urgency language",
                signalType: .keyword,
                category: nil,
                matches: { email in
                    containsAny(email.normalizedText, [
                        "urgent", "act now", "final hours", "last chance", "limited time"
                    ])
                }
            )
        ])

        base.append(contentsOf: enhancedSignals)

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

        // Add enhanced signals for Phase 1
        base.append(contentsOf: enhancedSignals)
        
        return base
    }

    private var yearScanSignals: [Signal] {
        var base: [Signal] = [
            Signal(
                id: "past_due",
                weight: 1.6,
                reason: "Past due or delinquent",
                signalType: .keyword,
                category: .payment,
                matches: { email in
                    containsAny(email.normalizedText, ["past due", "delinquent", "late fee", "overdue balance"])
                }
            ),
            Signal(
                id: "final_notice",
                weight: 1.8,
                reason: "Final notice or last warning",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, ["final notice", "last notice", "final warning"])
                }
            ),
            Signal(
                id: "collections",
                weight: 2.2,
                reason: "Collections or charge-off risk",
                signalType: .keyword,
                category: .payment,
                matches: { email in
                    containsAny(email.normalizedText, ["collections", "charge off", "sent to collections"])
                }
            ),
            Signal(
                id: "coverage_lapsed",
                weight: 1.9,
                reason: "Coverage lapsed",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, ["coverage lapsed", "policy lapsed", "coverage ended"])
                }
            ),
            Signal(
                id: "policy_canceled",
                weight: 2.0,
                reason: "Policy canceled",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, ["policy canceled", "coverage canceled", "policy terminated"])
                }
            ),
            Signal(
                id: "license_suspended",
                weight: 2.0,
                reason: "License or permit issue",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, ["license suspended", "permit expired", "license revoked"])
                }
            ),
            Signal(
                id: "tax_notice",
                weight: 2.0,
                reason: "Tax or government notice",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, ["tax notice", "irs notice", "state tax", "government notice"])
                }
            ),
            Signal(
                id: "court_notice",
                weight: 2.1,
                reason: "Court or legal notice",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, ["court notice", "summons", "subpoena", "legal notice"])
                }
            ),
            Signal(
                id: "benefits_deadline_missed",
                weight: 1.7,
                reason: "Benefits or enrollment deadline",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, ["enrollment deadline", "benefits enrollment", "coverage election"])
                }
            ),
            Signal(
                id: "identity_verification",
                weight: 1.6,
                reason: "Identity verification required",
                signalType: .keyword,
                category: .deadline,
                matches: { email in
                    containsAny(email.normalizedText, ["identity verification", "verify your identity", "kyc"])
                }
            )
        ]
        base.append(contentsOf: legalYearScanSignals)
        return base
    }
}

struct Signal {
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
