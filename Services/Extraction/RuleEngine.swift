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
    case accountChangeRequired
    case paymentFailure
    case documentExpiration
    case identityVerification
    case deliveryRequired
    case appointmentActionRequired
    case thirdPartyAwaitingYou
    case legalComplianceResponse
    case marketingNoise
}

struct HypothesisDefinition {
    let id: ObligationHypothesis
    let requiresAny: [String]
    let requiresAll: [String]
    let boosts: [String]
    let blocks: [String]
    let lowWithoutBoost: Bool
    let reasonTemplate: String
}

enum RuleEvaluationProfile: String, Codable {
    case digest
    case yearScanHighPrecision
}

enum DecisionPolicyVersion: String, Codable, CaseIterable {
    case v1StaticBridge = "v1_static_bridge"
    case v2PolicyDriven = "v2_policy_driven"
}

enum ReasonCode: String, Codable, CaseIterable {
    case directRequestWithDeadline = "direct_request_deadline"
    case directRequestWithoutDeadline = "direct_request_no_deadline"
    case deadlineMentioned = "deadline_only"
    case waitingOnThirdParty = "waiting_on_other"
    case legalCompliance = "legal_compliance"
    case accountVerification = "account_verification"
    case deliveryActionRequired = "delivery_action"
    case appointmentActionRequired = "appointment_action"
    case securityInformational = "security_informational"
    case receiptConfirmation = "receipt_confirmation"
    case marketingPromo = "marketing_promo"
    case other = "other"
}

struct DecisionContract: Codable, Hashable {
    let outcome: ObligationDecision
    let primaryHypothesisId: String?
    let reasonCodes: [ReasonCode]
    let reasonText: String
    let evidence: [String]
    let policyVersion: String
    let matchedHypotheses: [ObligationHypothesis]
    let confidence: HypothesisConfidence

    /// Primary reason code for backward-compatible read access. `reasonCodes` is authoritative.
    var reasonCode: ReasonCode { reasonCodes.first ?? .other }
}

enum ReasonCatalog {
    static func displayText(for reasonCode: ReasonCode) -> String {
        switch reasonCode {
        case .directRequestWithDeadline:
            return "Direct request with a clear deadline"
        case .directRequestWithoutDeadline:
            return "Direct request without a deadline"
        case .deadlineMentioned:
            return "Deadline mentioned without a request"
        case .waitingOnThirdParty:
            return "Waiting on someone else to respond"
        case .legalCompliance:
            return "Legal or compliance requirement"
        case .accountVerification:
            return "Account or identity verification required"
        case .deliveryActionRequired:
            return "Delivery or package action required"
        case .appointmentActionRequired:
            return "Appointment action required"
        case .securityInformational:
            return "Security alert / informational"
        case .receiptConfirmation:
            return "Receipt or confirmation only"
        case .marketingPromo:
            return "Marketing / newsletter / promo"
        case .other:
            return "Other..."
        }
    }

    static var labelingOptions: [String] {
        [
            displayText(for: .directRequestWithDeadline),
            displayText(for: .directRequestWithoutDeadline),
            displayText(for: .deadlineMentioned),
            displayText(for: .waitingOnThirdParty),
            displayText(for: .legalCompliance),
            displayText(for: .accountVerification),
            displayText(for: .deliveryActionRequired),
            displayText(for: .appointmentActionRequired),
            displayText(for: .securityInformational),
            displayText(for: .receiptConfirmation),
            displayText(for: .marketingPromo),
            displayText(for: .other)
        ]
    }

    static func shortChipText(for reasonCode: ReasonCode) -> String {
        switch reasonCode {
        case .directRequestWithDeadline, .directRequestWithoutDeadline: return "Request"
        case .deadlineMentioned: return "Deadline"
        case .waitingOnThirdParty: return "Follow-up"
        case .legalCompliance: return "Legal"
        case .accountVerification: return "Verify"
        case .deliveryActionRequired: return "Delivery"
        case .appointmentActionRequired: return "Appointment"
        case .securityInformational: return "Security"
        case .receiptConfirmation: return "Receipt"
        case .marketingPromo: return "Marketing"
        case .other: return "Other"
        }
    }

    static func code(from displayText: String) -> ReasonCode {
        let normalized = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        for code in ReasonCode.allCases where self.displayText(for: code) == normalized {
            return code
        }
        return .other
    }
}

struct DecisionPolicy {
    let version: DecisionPolicyVersion

    init(version: DecisionPolicyVersion = .v2PolicyDriven) {
        self.version = version
    }

    func hypothesisDefinitions(for profile: RuleEvaluationProfile) -> [HypothesisDefinition] {
        let digest = digestDefinitions
        switch profile {
        case .digest:
            return digest
        case .yearScanHighPrecision:
            return digest.filter {
                $0.id == .legalOrCompliance ||
                $0.id == .paymentFailure ||
                $0.id == .documentExpiration ||
                $0.id == .identityVerification ||
                $0.id == .appointmentActionRequired ||
                $0.id == .legalComplianceResponse
            }
        }
    }

    func decideOutcome(_ evaluations: [HypothesisEvaluation], profile: RuleEvaluationProfile) -> ObligationDecision {
        let byHypothesis = Dictionary(uniqueKeysWithValues: evaluations.map { ($0.hypothesis, $0) })
        let userAction = byHypothesis[.userActionRequired]
        let deadline = byHypothesis[.deadlineImplied]
        let waiting = byHypothesis[.waitingOnThirdParty]
        let legal = byHypothesis[.legalOrCompliance]
        let paymentFailure = byHypothesis[.paymentFailure]
        let documentExpiration = byHypothesis[.documentExpiration]
        let identityVerification = byHypothesis[.identityVerification]
        let legalComplianceResponse = byHypothesis[.legalComplianceResponse]
        let delivery = byHypothesis[.deliveryRequired]
        let appointment = byHypothesis[.appointmentActionRequired]
        let accountChange = byHypothesis[.accountChangeRequired]
        let thirdPartyAwaitingYou = byHypothesis[.thirdPartyAwaitingYou]

        if version == .v1StaticBridge {
            if let legalComplianceResponse, legalComplianceResponse.confidence != .low {
                return .accept
            }
            if let legal, legal.confidence != .low {
                return .accept
            }
            if paymentFailure?.confidence == .high {
                return .accept
            }
            if profile == .yearScanHighPrecision {
                if documentExpiration?.confidence == .high || identityVerification?.confidence == .high {
                    return .accept
                }
                return .reject
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
            if documentExpiration?.confidence == .medium || identityVerification?.confidence == .medium {
                return .needsReview
            }
            return .reject
        }

        if let legalComplianceResponse, legalComplianceResponse.confidence != .low {
            return .accept
        }
        if let legal, legal.confidence != .low {
            return .accept
        }
        if paymentFailure?.confidence == .high {
            return .accept
        }
        if profile == .yearScanHighPrecision {
            if documentExpiration?.confidence == .high || identityVerification?.confidence == .high {
                return .accept
            }
            if appointment?.confidence == .high {
                return .accept
            }
            return .reject
        }

        if userAction?.confidence == .high,
           deadline?.confidence == .high || deadline?.confidence == .medium {
            return .accept
        }

        if waiting?.confidence == .high {
            return .accept
        }

        if delivery?.confidence == .high || appointment?.confidence == .high || accountChange?.confidence == .high {
            return .needsReview
        }

        if thirdPartyAwaitingYou?.confidence == .high {
            return .needsReview
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
        if documentExpiration?.confidence == .medium || identityVerification?.confidence == .medium {
            return .needsReview
        }
        if delivery?.confidence == .medium || appointment?.confidence == .medium || accountChange?.confidence == .medium {
            return .needsReview
        }

        return .reject
    }

    var allHypotheses: Set<ObligationHypothesis> {
        Set(digestDefinitions.map(\.id))
    }

    var drivingHypotheses: Set<ObligationHypothesis> {
        [
            .legalComplianceResponse,
            .legalOrCompliance,
            .paymentFailure,
            .userActionRequired,
            .deadlineImplied,
            .waitingOnThirdParty,
            .documentExpiration,
            .identityVerification,
            .deliveryRequired,
            .appointmentActionRequired,
            .accountChangeRequired,
            .thirdPartyAwaitingYou
        ]
    }

    private var digestDefinitions: [HypothesisDefinition] {
        [
            HypothesisDefinition(
                id: .userActionRequired,
                requiresAny: ["request_keyword", "document_keyword", "payment_keyword"],
                requiresAll: [],
                boosts: ["direct_address", "attachment_present", "known_sender"],
                blocks: ["promo_keywords", "receipt_statement", "informational_update"],
                lowWithoutBoost: false,
                reasonTemplate: "This asks you to complete something directly."
            ),
            HypothesisDefinition(
                id: .deadlineImplied,
                requiresAny: ["deadline_keyword", "policy_keyword", "document_expires_soon"],
                requiresAll: ["date_detected"],
                boosts: ["deadline_keyword", "date_detected"],
                blocks: ["promo_urgency", "receipt_statement"],
                lowWithoutBoost: true,
                reasonTemplate: "This appears to include a real due date."
            ),
            HypothesisDefinition(
                id: .waitingOnThirdParty,
                requiresAny: ["waiting_on_phrase"],
                requiresAll: [],
                boosts: [],
                blocks: ["promo_keywords"],
                lowWithoutBoost: true,
                reasonTemplate: "This may need follow-up while waiting on someone else."
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
                lowWithoutBoost: false,
                reasonTemplate: "This looks like an official legal or compliance request."
            ),
            HypothesisDefinition(
                id: .accountChangeRequired,
                requiresAny: ["account_change_required", "identity_verification", "request_keyword"],
                requiresAll: [],
                boosts: ["known_sender", "direct_address", "date_detected"],
                blocks: ["security_alert", "promo_keywords"],
                lowWithoutBoost: true,
                reasonTemplate: "This asks you to update account details."
            ),
            HypothesisDefinition(
                id: .paymentFailure,
                requiresAny: ["autopay_failed", "past_due", "collections", "payment_keyword"],
                requiresAll: [],
                boosts: ["payment_keyword", "deadline_keyword"],
                blocks: ["receipt_statement"],
                lowWithoutBoost: false,
                reasonTemplate: "A payment issue appears to require action."
            ),
            HypothesisDefinition(
                id: .documentExpiration,
                requiresAny: ["document_expires_soon", "passport_renewal", "license_renewal"],
                requiresAll: ["date_detected"],
                boosts: ["document_keyword"],
                blocks: ["newsletter", "marketing_language"],
                lowWithoutBoost: true,
                reasonTemplate: "A document may expire and need renewal."
            ),
            HypothesisDefinition(
                id: .identityVerification,
                requiresAny: ["identity_verification", "request_keyword"],
                requiresAll: [],
                boosts: ["known_sender", "direct_address"],
                blocks: ["security_alert", "promo_keywords"],
                lowWithoutBoost: true,
                reasonTemplate: "Identity verification appears to be required."
            ),
            HypothesisDefinition(
                id: .deliveryRequired,
                requiresAny: ["delivery_action_required", "request_keyword"],
                requiresAll: [],
                boosts: ["date_detected"],
                blocks: ["newsletter", "promo_label"],
                lowWithoutBoost: true,
                reasonTemplate: "A delivery step may need your attention."
            ),
            HypothesisDefinition(
                id: .appointmentActionRequired,
                requiresAny: ["medical_appointment", "uscis_biometrics", "uscis_interview", "travel_keyword"],
                requiresAll: [],
                boosts: ["date_detected", "request_keyword"],
                blocks: ["newsletter", "promotional_label"],
                lowWithoutBoost: true,
                reasonTemplate: "An appointment likely needs confirmation or preparation."
            ),
            HypothesisDefinition(
                id: .thirdPartyAwaitingYou,
                requiresAny: ["waiting_on_phrase"],
                requiresAll: ["request_keyword"],
                boosts: ["direct_address"],
                blocks: ["informational_update"],
                lowWithoutBoost: true,
                reasonTemplate: "A third party is waiting on your response."
            ),
            HypothesisDefinition(
                id: .legalComplianceResponse,
                requiresAny: ["legal_notice", "court_notice", "tax_notice", "immigration_deadline", "irs_notice"],
                requiresAll: ["date_detected"],
                boosts: ["legal_sender_gov_allowlist", "legal_sender_courts", "legal_sender_irs", "legal_sender_uscis"],
                blocks: [],
                lowWithoutBoost: false,
                reasonTemplate: "An official response appears required by a deadline."
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
                lowWithoutBoost: true,
                reasonTemplate: "This appears promotional or informational."
            )
        ]
    }
}

struct HypothesisReviewContext: Hashable, Codable {
    let senderDomainClass: String
    let labelCluster: String
    let threadPattern: String
}

struct HypothesisReviewCalibrationSnapshot {
    let needsReviewConfidenceByKey: [String: Double]

    static let empty = HypothesisReviewCalibrationSnapshot(needsReviewConfidenceByKey: [:])

    func confidenceOverride(for hypothesisId: ObligationHypothesis, context: HypothesisReviewContext) -> Double? {
        let scoped = Self.key(hypothesisId: hypothesisId, context: context)
        if let scopedValue = needsReviewConfidenceByKey[scoped] {
            return scopedValue
        }
        return needsReviewConfidenceByKey[Self.globalKey(hypothesisId: hypothesisId)]
    }

    static func key(hypothesisId: ObligationHypothesis, context: HypothesisReviewContext) -> String {
        [
            hypothesisId.rawValue,
            context.senderDomainClass,
            context.labelCluster,
            context.threadPattern
        ].joined(separator: "|")
    }

    static func globalKey(hypothesisId: ObligationHypothesis) -> String {
        [hypothesisId.rawValue, "all", "all", "all"].joined(separator: "|")
    }
}

struct HypothesisMetricsEvent {
    let profile: RuleEvaluationProfile
    let fired: [ObligationHypothesis: Int]
    let blocked: [ObligationHypothesis: Int]
    let accepted: [ObligationHypothesis: Int]
    let review: [ObligationHypothesis: Int]
    let rejected: Int
    let blockerBypassSignals: [String]

    var asLogFields: [String: CustomStringConvertible] {
        [
            "profile": profile.rawValue,
            "fired": mapToString(fired),
            "blocked": mapToString(blocked),
            "accepted": mapToString(accepted),
            "review": mapToString(review),
            "rejected": rejected,
            "blockerBypassSignals": blockerBypassSignals.joined(separator: ",")
        ]
    }

    private func mapToString(_ source: [ObligationHypothesis: Int]) -> String {
        source
            .map { ($0.key.rawValue, $0.value) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0):\($0.1)" }
            .joined(separator: ",")
    }
}

struct HypothesisEvaluation {
    let hypothesis: ObligationHypothesis
    let confidence: HypothesisConfidence
    let reasons: [String]
    let matchedSignals: [String]
}

struct HypothesisResultSnapshot: Codable, Hashable {
    let hypothesisId: String
    let confidence: String
    let reasons: [String]
    let matchedSignalIds: [String]
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
    let matchedSignalIds: [String]
    let matchedRuleIds: [String]
    let matchedSignalTypes: [SignalType]
    let matchedReasons: [String]
    let hypothesisResults: [HypothesisResultSnapshot]
    let decisionContract: DecisionContract
}

/// Personalization-agnostic deterministic decision engine.
/// This type must remain global-policy driven and must not apply user-specific adaptation.
final class RuleEngine {
    private let preferences: FilterPreferencesStoring
    private let decisionPolicy: DecisionPolicy
    private let reviewExplosionThreshold: Int = 4
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

    init(preferences: FilterPreferencesStoring, policyVersion: DecisionPolicyVersion = .v2PolicyDriven) {
        self.preferences = preferences
        self.decisionPolicy = DecisionPolicy(version: policyVersion)
    }

    func evaluate(email: ParsedEmail, weightMultipliers: [String: Double] = [:]) -> RuleAssessment? {
        let assessment = assess(email: email, weightMultipliers: weightMultipliers, profile: .digest)
        return isAccepted(assessment) ? assessment : nil
    }

    func assess(
        email: ParsedEmail,
        weightMultipliers: [String: Double] = [:],
        profile: RuleEvaluationProfile = .digest,
        reviewCalibration: HypothesisReviewCalibrationSnapshot = .empty
    ) -> RuleAssessment {
        let context = reviewContext(for: email)
        return buildHypothesisAssessment(
            email: email,
            profile: profile,
            reviewCalibration: reviewCalibration,
            reviewContext: context
        )
    }

    func evaluateYearScan(email: ParsedEmail) -> RuleAssessment? {
        let assessment = buildHypothesisAssessment(
            email: email,
            profile: .yearScanHighPrecision,
            reviewCalibration: .empty,
            reviewContext: reviewContext(for: email)
        )
        guard assessment.decision == .accept else { return nil }
        let yearScanHypothesisAllowlist: Set<String> = [
            ObligationHypothesis.legalOrCompliance.rawValue,
            ObligationHypothesis.legalComplianceResponse.rawValue,
            ObligationHypothesis.paymentFailure.rawValue,
            ObligationHypothesis.documentExpiration.rawValue,
            ObligationHypothesis.identityVerification.rawValue,
            ObligationHypothesis.appointmentActionRequired.rawValue
        ]
        guard assessment.matchedRuleIds.contains(where: { yearScanHypothesisAllowlist.contains($0) }) else {
            return nil
        }
        return assessment
    }

    func evaluateYearScanLegacy(email: ParsedEmail) -> RuleAssessment? {
        let assessment = buildAssessment(
            email: email,
            signals: yearScanSignals,
            includeDate: false,
            weightMultipliers: [:]
        )
        guard assessment.score >= 2.6 else { return nil }
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
        let candidates = [email.snippet, email.subject, email.bodyText]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(140))
            }
        }
        return ""
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

        let parsedDeadline = includeDate ? DateParsing.parseDate(from: email.normalizedText) : nil
        if includeDate, parsedDeadline != nil {
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
            decision: .accept,
            score: score,
            category: category,
            risk: risk,
            confidence: confidence,
            evidenceQuote: evidenceQuote,
            deadline: parsedDeadline,
            matchedSignalIds: matches.map(\.id),
            matchedRuleIds: matches.map(\.id),
            matchedSignalTypes: matches.map(\.signalType),
            matchedReasons: matches.map(\.reason),
            hypothesisResults: [],
            decisionContract: DecisionContract(
                outcome: .accept,
                primaryHypothesisId: nil,
                reasonCodes: [.other],
                reasonText: ReasonCatalog.displayText(for: .other),
                evidence: matches.map(\.reason),
                policyVersion: decisionPolicy.version.rawValue,
                matchedHypotheses: [],
                confidence: .low
            )
        )
    }

    private func buildHypothesisAssessment(
        email: ParsedEmail,
        profile: RuleEvaluationProfile,
        reviewCalibration: HypothesisReviewCalibrationSnapshot,
        reviewContext: HypothesisReviewContext
    ) -> RuleAssessment {
        let parsedDeadline = DateParsing.parseDate(from: email.normalizedText)
        let matchedSignals = matchSignals(email: email, includeDate: true, parsedDeadline: parsedDeadline)
        let matchedIds = Set(matchedSignals.map(\.id))
        let matchedSignalTypes = Array(Set(matchedSignals.map(\.signalType)))

        let globalBlockers = matchedSignals.filter { globalBlockerSignalIds.contains($0.id) }
        if !globalBlockers.isEmpty {
            let reasons = uniqueReasons(from: globalBlockers)
            let blockerReasonCode = inferReasonCode(for: .reject, primaryHypothesisId: .marketingNoise, reasons: reasons)
            let contract = DecisionContract(
                outcome: .reject,
                primaryHypothesisId: ObligationHypothesis.marketingNoise.rawValue,
                reasonCodes: [blockerReasonCode],
                reasonText: ReasonCatalog.displayText(for: blockerReasonCode),
                evidence: reasons,
                policyVersion: decisionPolicy.version.rawValue,
                matchedHypotheses: [.marketingNoise],
                confidence: .high
            )
            return RuleAssessment(
                decision: .reject,
                score: 0.0,
                category: .other,
                risk: .low,
                confidence: 0.3,
                evidenceQuote: makeEvidenceQuote(from: email),
                deadline: parsedDeadline,
                matchedSignalIds: matchedSignals.map(\.id),
                matchedRuleIds: [ObligationHypothesis.marketingNoise.rawValue],
                matchedSignalTypes: matchedSignalTypes,
                matchedReasons: reasons,
                hypothesisResults: [
                    HypothesisResultSnapshot(
                        hypothesisId: ObligationHypothesis.marketingNoise.rawValue,
                        confidence: HypothesisConfidence.high.rawValue,
                        reasons: reasons,
                        matchedSignalIds: matchedSignals.map(\.id).sorted()
                    )
                ],
                decisionContract: contract
            )
        }

        let evaluations = evaluateHypotheses(
            matchedIds: matchedIds,
            matchedSignals: matchedSignals,
            profile: profile
        )
        emitHypothesisDebug(
            emailId: email.subject,
            matchedIds: matchedIds,
            matchedSignals: matchedSignals,
            evaluations: evaluations
        )
        let decision = decideOutcome(evaluations, profile: profile)
        let confidence = confidenceValue(
            for: decision,
            evaluations: evaluations,
            profile: profile,
            reviewCalibration: reviewCalibration,
            reviewContext: reviewContext
        )
        let reasons = reasonsForOutcome(evaluations)
        let primaryHypothesisEval = evaluations
            .sorted { confidenceRank($0.confidence) > confidenceRank($1.confidence) }
            .first
        let primaryHypothesis = primaryHypothesisEval?.hypothesis
        let contractConfidence = primaryHypothesisEval?.confidence ?? .low
        let reasonCode = inferReasonCode(
            for: decision,
            primaryHypothesisId: primaryHypothesis,
            reasons: reasons
        )
        let decisionContract = DecisionContract(
            outcome: decision,
            primaryHypothesisId: primaryHypothesis?.rawValue,
            reasonCodes: [reasonCode],
            reasonText: ReasonCatalog.displayText(for: reasonCode),
            evidence: reasons,
            policyVersion: decisionPolicy.version.rawValue,
            matchedHypotheses: evaluations.map { $0.hypothesis },
            confidence: contractConfidence
        )
        let category = determineCategory(from: matchedSignals, evaluations: evaluations)
        let risk = determineRisk(evaluations: evaluations)
        emitMetrics(
            profile: profile,
            evaluations: evaluations,
            decision: decision,
            globalBlockers: globalBlockers,
            matchedIds: matchedIds
        )

        return RuleAssessment(
            decision: decision,
            score: confidence,
            category: category,
            risk: risk,
            confidence: confidence,
            evidenceQuote: makeEvidenceQuote(from: email),
            deadline: parsedDeadline,
            matchedSignalIds: Array(matchedIds).sorted(),
            matchedRuleIds: evaluations.map { $0.hypothesis.rawValue },
            matchedSignalTypes: matchedSignalTypes,
            matchedReasons: reasons,
            hypothesisResults: evaluations
                .map {
                    HypothesisResultSnapshot(
                        hypothesisId: $0.hypothesis.rawValue,
                        confidence: $0.confidence.rawValue,
                        reasons: $0.reasons,
                        matchedSignalIds: $0.matchedSignals.sorted()
                    )
                }
                .sorted { $0.hypothesisId < $1.hypothesisId },
            decisionContract: decisionContract
        )
    }

    private struct MatchedSignal {
        let id: String
        let reason: String
        let signalType: SignalType
        let category: ObligationCategory?
    }

    private func matchSignals(email: ParsedEmail, includeDate: Bool, parsedDeadline: Date? = nil) -> [MatchedSignal] {
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
        let resolvedDeadline = parsedDeadline ?? (includeDate ? DateParsing.parseDate(from: email.normalizedText) : nil)
        if includeDate, resolvedDeadline != nil {
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

    private func hypothesisDefinitions(for profile: RuleEvaluationProfile) -> [HypothesisDefinition] {
        decisionPolicy.hypothesisDefinitions(for: profile)
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
        matchedSignals: [MatchedSignal],
        profile: RuleEvaluationProfile
    ) -> [HypothesisEvaluation] {
        hypothesisDefinitions(for: profile).compactMap { definition in
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
            let withTemplate = reasons.isEmpty ? [definition.reasonTemplate] : reasons + [definition.reasonTemplate]
            let matched = reasonSignals.map(\.id)

            return HypothesisEvaluation(
                hypothesis: definition.id,
                confidence: confidence,
                reasons: withTemplate,
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
        for definition in hypothesisDefinitions(for: .digest) {
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

    private func decideOutcome(_ evaluations: [HypothesisEvaluation], profile: RuleEvaluationProfile) -> ObligationDecision {
        decisionPolicy.decideOutcome(evaluations, profile: profile)
    }

    private func confidenceValue(
        for decision: ObligationDecision,
        evaluations: [HypothesisEvaluation],
        profile: RuleEvaluationProfile,
        reviewCalibration: HypothesisReviewCalibrationSnapshot,
        reviewContext: HypothesisReviewContext
    ) -> Double {
        let maxConfidence = evaluations.map(\.confidence).sorted(by: { lhs, rhs in
            confidenceRank(lhs) > confidenceRank(rhs)
        }).first

        switch decision {
        case .accept:
            return confidenceValue(for: maxConfidence ?? .medium)
        case .needsReview:
            guard profile == .digest else { return confidenceValue(for: .low) }
            guard let primary = evaluations.sorted(by: { confidenceRank($0.confidence) > confidenceRank($1.confidence) }).first else {
                return confidenceValue(for: .low)
            }
            let calibrated = reviewCalibration.confidenceOverride(for: primary.hypothesis, context: reviewContext)
            return min(max(calibrated ?? confidenceValue(for: .low), 0.45), 0.62)
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
        let parsedDeadline = DateParsing.parseDate(from: email.normalizedText)
        let matchedSignals = matchSignals(email: email, includeDate: true, parsedDeadline: parsedDeadline)
        let matchedIds = Set(matchedSignals.map(\.id))
        let evaluations = evaluateHypotheses(matchedIds: matchedIds, matchedSignals: matchedSignals, profile: .digest)
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

    private func inferReasonCode(
        for decision: ObligationDecision,
        primaryHypothesisId: ObligationHypothesis?,
        reasons: [String]
    ) -> ReasonCode {
        let combined = reasons.joined(separator: " ").lowercased()
        if decision == .reject {
            if combined.contains("marketing") || combined.contains("promo") || combined.contains("unsubscribe") {
                return .marketingPromo
            }
            if combined.contains("security") || combined.contains("informational") || combined.contains("newsletter") {
                return .securityInformational
            }
            if combined.contains("receipt") || combined.contains("statement") || combined.contains("confirmation") {
                return .receiptConfirmation
            }
        }
        switch primaryHypothesisId {
        case .deliveryRequired:
            return .deliveryActionRequired
        case .appointmentActionRequired:
            return .appointmentActionRequired
        case .accountChangeRequired, .identityVerification:
            return .accountVerification
        case .legalOrCompliance, .legalComplianceResponse:
            return .legalCompliance
        case .waitingOnThirdParty, .thirdPartyAwaitingYou:
            return .waitingOnThirdParty
        case .deadlineImplied:
            return .deadlineMentioned
        case .paymentFailure:
            return .directRequestWithDeadline
        case .marketingNoise:
            return .marketingPromo
        case .userActionRequired:
            return combined.contains("date") || combined.contains("deadline")
                ? .directRequestWithDeadline
                : .directRequestWithoutDeadline
        case .documentExpiration:
            return .deadlineMentioned
        case .none:
            return .other
        }
    }

    private func reviewContext(for email: ParsedEmail) -> HypothesisReviewContext {
        HypothesisReviewContext(
            senderDomainClass: senderDomainClass(for: email.senderDomain),
            labelCluster: labelCluster(for: email.labelIds),
            threadPattern: threadPattern(for: email.subject)
        )
    }

    private func senderDomainClass(for senderDomain: String?) -> String {
        guard let domain = senderDomain?.lowercased(), !domain.isEmpty else { return "unknown" }
        let free = ["gmail.com", "yahoo.com", "outlook.com", "hotmail.com", "icloud.com"]
        if domain.hasSuffix(".gov") || domain.hasSuffix(".mil") { return "government" }
        if free.contains(domain) { return "consumer" }
        return "business"
    }

    private func labelCluster(for labels: [String]) -> String {
        let normalized = Set(labels.map { $0.lowercased() })
        if normalized.contains("category_promotions") || normalized.contains("promotions") {
            return "promotions"
        }
        if normalized.contains("category_social") || normalized.contains("social") {
            return "social"
        }
        if normalized.contains("inbox") {
            return "inbox"
        }
        return "other"
    }

    private func threadPattern(for subject: String) -> String {
        let normalized = subject.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("re:") || normalized.hasPrefix("fwd:") {
            return "replyChain"
        }
        return "newThread"
    }

    private func emitMetrics(
        profile: RuleEvaluationProfile,
        evaluations: [HypothesisEvaluation],
        decision: ObligationDecision,
        globalBlockers: [MatchedSignal],
        matchedIds: Set<String>
    ) {
        var fired: [ObligationHypothesis: Int] = [:]
        var blocked: [ObligationHypothesis: Int] = [:]
        var accepted: [ObligationHypothesis: Int] = [:]
        var review: [ObligationHypothesis: Int] = [:]
        for evaluation in evaluations {
            fired[evaluation.hypothesis, default: 0] += 1
            switch decision {
            case .accept:
                accepted[evaluation.hypothesis, default: 0] += 1
            case .needsReview:
                review[evaluation.hypothesis, default: 0] += 1
            case .reject:
                blocked[evaluation.hypothesis, default: 0] += 1
            }
        }
        let reviewCount = review.values.reduce(0, +)
        var bypass: [String] = []
        if !globalBlockers.isEmpty && decision != .reject {
            bypass = globalBlockers.map(\.id)
        }
        if reviewCount >= reviewExplosionThreshold {
            AppLog.debug(
                "RuleEngine.reviewExplosionGuard",
                fields: [
                    "profile": profile.rawValue,
                    "reviewCount": reviewCount,
                    "matchedSignals": matchedIds.sorted().joined(separator: ",")
                ]
            )
        }
        let event = HypothesisMetricsEvent(
            profile: profile,
            fired: fired,
            blocked: blocked,
            accepted: accepted,
            review: review,
            rejected: decision == .reject ? 1 : 0,
            blockerBypassSignals: bypass
        )
        AppLog.debug("RuleEngine.hypothesisCounters", fields: event.asLogFields)
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
                        "newsletter", "weekly update", "product update", "news", "digest", "weekly roundup",
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
