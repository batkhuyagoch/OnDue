import Foundation
@preconcurrency import Combine

protocol ObligationExtracting: Sendable {
    func extract(from messages: [MessageRecord], mailboxAccountId: String) async throws -> [ObligationRecord]
    func assess(message: MessageRecord, mailboxAccountId: String) async throws -> RuleAssessment
    func makeObligation(from assessment: RuleAssessment, message: MessageRecord, mailboxAccountId: String, messagePk: Int64) -> ObligationRecord
    func scanYear(messages: [MessageRecord], mailboxAccountId: String) async throws -> [YearScanItem]
}

final class ObligationExtractor: ObligationExtracting, @unchecked Sendable {
    private static let compareLegacyPolicyFlagKey = "debug.yearScan.compareLegacyPolicy"
    private static let compareLegacySamplePercentKey = "debug.yearScan.compareLegacySamplePercent"

    private let parser = EmailParser()
    private let ruleEngine: RuleEngine
    private let ruleWeightRepository: RuleWeightRepositorying
    private let hypothesisReviewCalibrationRepository: HypothesisReviewCalibrationRepositorying
    private let hypothesisMetricsRepository: HypothesisMetricsRepositorying
    private let candidateScoreRepository: CandidateScoreRepositorying
    private let suppressionRepository: SuppressionRepositorying?
    private let compareLegacyPolicyDuringYearScan: Bool
    private let compareLegacySamplePercent: Int

    init(
        preferences: FilterPreferencesStoring,
        ruleWeightRepository: RuleWeightRepositorying,
        hypothesisReviewCalibrationRepository: HypothesisReviewCalibrationRepositorying,
        hypothesisMetricsRepository: HypothesisMetricsRepositorying,
        candidateScoreRepository: CandidateScoreRepositorying,
        suppressionRepository: SuppressionRepositorying? = nil
    ) {
        self.ruleEngine = RuleEngine(preferences: preferences)
        self.ruleWeightRepository = ruleWeightRepository
        self.hypothesisReviewCalibrationRepository = hypothesisReviewCalibrationRepository
        self.hypothesisMetricsRepository = hypothesisMetricsRepository
        self.candidateScoreRepository = candidateScoreRepository
        self.suppressionRepository = suppressionRepository
        self.compareLegacyPolicyDuringYearScan = UserDefaults.standard.bool(forKey: Self.compareLegacyPolicyFlagKey)
        let samplePercent = UserDefaults.standard.integer(forKey: Self.compareLegacySamplePercentKey)
        self.compareLegacySamplePercent = min(max(samplePercent, 0), 100)
    }

    func extract(from messages: [MessageRecord], mailboxAccountId: String) async throws -> [ObligationRecord] {
        let multipliers = try await ruleWeightRepository.fetchMultipliers(mailboxAccountId: mailboxAccountId)
        let reviewCalibration = try await hypothesisReviewCalibrationRepository.fetchSnapshot(mailboxAccountId: mailboxAccountId)
        var acceptedByThread: [String: (assessment: RuleAssessment, message: MessageRecord, messagePk: Int64)] = [:]

        for message in messages {
            guard let pk = message.pk else { continue }
            if let suppressionRepository {
                let blocked = (try? await suppressionRepository.isBlocked(
                    mailboxAccountId: mailboxAccountId,
                    sender: message.fromEmail,
                    domain: message.fromDomain
                )) ?? false
                if blocked {
                    try? await candidateScoreRepository.delete(messagePk: pk)
                    continue
                }
            }
            let parsedEmail = parser.parse(message: message)
            let assessment = ruleEngine.assess(
                email: parsedEmail,
                weightMultipliers: multipliers,
                profile: .digest,
                reviewCalibration: reviewCalibration
            )
            let threadKey = normalizedThreadKey(threadId: message.threadId, providerMessageId: message.providerMessageId)

            if ruleEngine.isAccepted(assessment) || ruleEngine.isBorderline(assessment) {
                try? await hypothesisMetricsRepository.increment(
                    mailboxAccountId: mailboxAccountId,
                    profile: .digest,
                    hypothesisIds: assessment.matchedRuleIds,
                    counter: ruleEngine.isAccepted(assessment) ? "accepted" : "review"
                )
                if let existing = acceptedByThread[threadKey] {
                    if isPreferred(assessment, over: existing.assessment) {
                        acceptedByThread[threadKey] = (assessment, message, pk)
                    }
                } else {
                    acceptedByThread[threadKey] = (assessment, message, pk)
                }
                try? await candidateScoreRepository.delete(messagePk: pk)
            } else {
                try? await hypothesisMetricsRepository.increment(
                    mailboxAccountId: mailboxAccountId,
                    profile: .digest,
                    hypothesisIds: assessment.matchedRuleIds.isEmpty ? [ObligationHypothesis.marketingNoise.rawValue] : assessment.matchedRuleIds,
                    counter: "blocked"
                )
                try? await candidateScoreRepository.delete(messagePk: pk)
            }
        }

        return acceptedByThread.values.map { entry in
            makeObligation(
                from: entry.assessment,
                message: entry.message,
                mailboxAccountId: mailboxAccountId,
                messagePk: entry.messagePk
            )
        }
    }

    func assess(message: MessageRecord, mailboxAccountId: String) async throws -> RuleAssessment {
        let multipliers = try await ruleWeightRepository.fetchMultipliers(mailboxAccountId: mailboxAccountId)
        let reviewCalibration = try await hypothesisReviewCalibrationRepository.fetchSnapshot(mailboxAccountId: mailboxAccountId)
        let parsedEmail = parser.parse(message: message)
        return ruleEngine.assess(
            email: parsedEmail,
            weightMultipliers: multipliers,
            profile: .digest,
            reviewCalibration: reviewCalibration
        )
    }

    func makeObligation(
        from assessment: RuleAssessment,
        message: MessageRecord,
        mailboxAccountId: String,
        messagePk: Int64
    ) -> ObligationRecord {
        guard let primaryHypothesisId = assessment.decisionContract.primaryHypothesisId,
              !primaryHypothesisId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preconditionFailure("Canonical decision integrity violation: missing primaryHypothesisId for persisted obligation.")
        }
        let reasonCode = assessment.decisionContract.reasonCode.rawValue
        let policyVersion = assessment.decisionContract.policyVersion
        guard !reasonCode.isEmpty, !policyVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preconditionFailure("Canonical decision integrity violation: missing reasonCode or policyVersion.")
        }
        let obligationKey = makeObligationKey(
            mailboxAccountId: mailboxAccountId,
            senderDomain: message.fromDomain,
            matchedRuleIds: assessment.matchedRuleIds
        )
        return ObligationRecord(
            mailboxAccountId: mailboxAccountId,
            messagePk: messagePk,
            category: assessment.category,
            title: message.subject,
            deadlineAt: assessment.deadline,
            risk: assessment.risk,
            whoOwes: .me,
            confidence: assessment.confidence,
            evidenceQuote: assessment.evidenceQuote,
            obligationKey: obligationKey,
            score: assessment.score,
            matchedRuleIds: assessment.matchedRuleIds.joined(separator: ","),
            matchedSignalTypes: assessment.matchedSignalTypes.map { $0.rawValue }.joined(separator: ","),
            matchedReasons: assessment.matchedReasons.joined(separator: " | "),
            primaryHypothesisId: primaryHypothesisId,
            reasonCode: reasonCode,
            policyVersion: policyVersion,
            repeatCount: 1,
            lastSeenAt: message.internalDate
        )
    }

    func scanYear(messages: [MessageRecord], mailboxAccountId: String) async throws -> [YearScanItem] {
        var bestByThread: [String: YearScanItem] = [:]

        for message in messages {
            guard let pk = message.pk else { continue }
            let parsedEmail = parser.parse(message: message)
            let migrated = ruleEngine.evaluateYearScan(email: parsedEmail)
            if shouldCompareLegacyDecision(for: message.providerMessageId) {
                let legacy = ruleEngine.evaluateYearScanLegacy(email: parsedEmail)
                if (legacy != nil) != (migrated != nil) {
                    AppLog.info(
                        "YearScan.migrationDisagreement",
                        fields: [
                            "mailboxAccountId": mailboxAccountId,
                            "subject": message.subject,
                            "legacyAccepted": legacy != nil,
                            "migratedAccepted": migrated != nil
                        ]
                    )
                }
            }
            guard let assessment = migrated else { continue }

            let blockedBySuppression: Bool
            if let suppressionRepository {
                blockedBySuppression = (try? await suppressionRepository.isBlocked(
                    mailboxAccountId: mailboxAccountId,
                    sender: message.fromEmail,
                    domain: message.fromDomain
                )) ?? false
            } else {
                blockedBySuppression = false
            }
            try? await hypothesisMetricsRepository.increment(
                mailboxAccountId: mailboxAccountId,
                profile: .yearScanHighPrecision,
                hypothesisIds: assessment.matchedRuleIds,
                counter: "accepted"
            )
            let threadKey = normalizedThreadKey(threadId: message.threadId, providerMessageId: message.providerMessageId)

            let displaySnippet = bestDisplaySnippet(
                snippet: parsedEmail.snippet,
                evidence: assessment.evidenceQuote,
                subject: parsedEmail.subject
            )

            let promotion = mapLongScanPromotionDecision(
                assessment: assessment,
                blockedBySuppression: blockedBySuppression
            )
            let item = YearScanItem(
                mailboxAccountId: mailboxAccountId,
                messagePk: pk,
                providerMessageId: message.providerMessageId,
                threadId: message.threadId,
                subject: message.subject,
                snippet: displaySnippet,
                score: assessment.score,
                matchedReasons: assessment.matchedReasons,
                source: .scan,
                promotionDecision: promotion.decision,
                promotionReasonCode: promotion.reasonCode,
                confidence: assessment.confidence,
                dueDate: assessment.deadline
            )

            if let existing = bestByThread[threadKey] {
                if item.isHigherPriority(than: existing) {
                    bestByThread[threadKey] = item
                }
            } else {
                bestByThread[threadKey] = item
            }
        }

        return bestByThread.values.sorted { lhs, rhs in
            if lhs.promotionDecision != rhs.promotionDecision {
                return lhs.isHigherPriority(than: rhs)
            }
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.detectedAt > rhs.detectedAt
        }
    }

    private func mapLongScanPromotionDecision(
        assessment: RuleAssessment,
        blockedBySuppression: Bool
    ) -> (decision: LongScanPromotionDecision, reasonCode: LongScanPromotionReasonCode) {
        if blockedBySuppression {
            return (.dropped, .suppressed)
        }

        // Precision-first guardrail for long scans.
        if assessment.confidence < 0.62 {
            return (.dropped, .lowConfidence)
        }

        guard assessment.deadline != nil else {
            if assessment.confidence >= 0.80 {
                return (.expectedEvent, .convertedExpectedEvent)
            }
            return (.dropped, .missingDueDate)
        }

        return (.promoted, .promotedActionable)
    }

    private func bestDisplaySnippet(snippet: String, evidence: String, subject: String) -> String {
        let orderedCandidates = [snippet, evidence, subject]
        for candidate in orderedCandidates {
            let normalized = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if isUsableDisplayText(normalized) {
                return normalized
            }
        }
        return subject.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isUsableDisplayText(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let visibleScalars = value.unicodeScalars.filter { scalar in
            let category = scalar.properties.generalCategory
            if category == .control || category == .format {
                return false
            }
            return !scalar.properties.isWhitespace
        }
        guard !visibleScalars.isEmpty else { return false }
        let visibleText = String(String.UnicodeScalarView(visibleScalars))
        let alphaNumericCount = visibleText.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count
        return alphaNumericCount >= 4
    }

    private func isPreferred(_ candidate: RuleAssessment, over existing: RuleAssessment) -> Bool {
        if candidate.confidence != existing.confidence {
            return candidate.confidence > existing.confidence
        }
        if candidate.score != existing.score {
            return candidate.score > existing.score
        }
        if let candidateDeadline = candidate.deadline, let existingDeadline = existing.deadline {
            return candidateDeadline < existingDeadline
        }
        if candidate.deadline != nil && existing.deadline == nil {
            return true
        }
        return false
    }

    private func makeObligationKey(
        mailboxAccountId: String,
        senderDomain: String?,
        matchedRuleIds: [String]
    ) -> String {
        let domain = (senderDomain ?? "unknown").lowercased()
        let rulesKey = matchedRuleIds.map { $0.lowercased() }.sorted().joined(separator: "|")
        return "\(mailboxAccountId)|\(domain)|\(rulesKey)"
    }

    private func normalizedThreadKey(threadId: String?, providerMessageId: String) -> String {
        let normalizedThreadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedThreadId, !normalizedThreadId.isEmpty {
            return normalizedThreadId
        }
        return providerMessageId
    }

    private func shouldCompareLegacyDecision(for providerMessageId: String) -> Bool {
        if compareLegacyPolicyDuringYearScan {
            return true
        }
        guard compareLegacySamplePercent > 0 else {
            return false
        }
        return Self.stableBucket(for: providerMessageId) < compareLegacySamplePercent
    }

    private static func stableBucket(for value: String) -> Int {
        value.unicodeScalars.reduce(into: 0) { partial, scalar in
            partial = (partial &* 31 &+ Int(scalar.value)) % 100
        }
    }
}
