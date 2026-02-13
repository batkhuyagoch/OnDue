import Foundation
@preconcurrency import Combine

protocol ObligationExtracting: Sendable {
    func extract(from messages: [MessageRecord], mailboxAccountId: String) async throws -> [ObligationRecord]
    func assess(message: MessageRecord, mailboxAccountId: String) async throws -> RuleAssessment
    func makeObligation(from assessment: RuleAssessment, message: MessageRecord, mailboxAccountId: String, messagePk: Int64) -> ObligationRecord
    func scanYear(messages: [MessageRecord], mailboxAccountId: String) async throws -> [YearScanItem]
}

final class ObligationExtractor: ObligationExtracting, @unchecked Sendable {
    private let parser = EmailParser()
    private let ruleEngine: RuleEngine
    private let ruleWeightRepository: RuleWeightRepositorying
    private let candidateScoreRepository: CandidateScoreRepositorying
    private let suppressionRepository: SuppressionRepositorying?

    init(
        preferences: FilterPreferencesStoring,
        ruleWeightRepository: RuleWeightRepositorying,
        candidateScoreRepository: CandidateScoreRepositorying,
        suppressionRepository: SuppressionRepositorying? = nil
    ) {
        self.ruleEngine = RuleEngine(preferences: preferences)
        self.ruleWeightRepository = ruleWeightRepository
        self.candidateScoreRepository = candidateScoreRepository
        self.suppressionRepository = suppressionRepository
    }

    func extract(from messages: [MessageRecord], mailboxAccountId: String) async throws -> [ObligationRecord] {
        let multipliers = try await ruleWeightRepository.fetchMultipliers(mailboxAccountId: mailboxAccountId)
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
            let assessment = ruleEngine.assess(email: parsedEmail, weightMultipliers: multipliers)
            let threadKey = message.threadId ?? message.providerMessageId

            if ruleEngine.isAccepted(assessment) || ruleEngine.isBorderline(assessment) {
                if let existing = acceptedByThread[threadKey] {
                    if isPreferred(assessment, over: existing.assessment) {
                        acceptedByThread[threadKey] = (assessment, message, pk)
                    }
                } else {
                    acceptedByThread[threadKey] = (assessment, message, pk)
                }
                try? await candidateScoreRepository.delete(messagePk: pk)
            } else {
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
        let parsedEmail = parser.parse(message: message)
        return ruleEngine.assess(email: parsedEmail, weightMultipliers: multipliers)
    }

    func makeObligation(
        from assessment: RuleAssessment,
        message: MessageRecord,
        mailboxAccountId: String,
        messagePk: Int64
    ) -> ObligationRecord {
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
            repeatCount: 1,
            lastSeenAt: message.internalDate
        )
    }

    func scanYear(messages: [MessageRecord], mailboxAccountId: String) async throws -> [YearScanItem] {
        var bestByThread: [String: YearScanItem] = [:]

        for message in messages {
            guard let pk = message.pk else { continue }
            if let suppressionRepository {
                let blocked = (try? await suppressionRepository.isBlocked(
                    mailboxAccountId: mailboxAccountId,
                    sender: message.fromEmail,
                    domain: message.fromDomain
                )) ?? false
                if blocked {
                    continue
                }
            }
            let parsedEmail = parser.parse(message: message)
            guard let assessment = ruleEngine.evaluateYearScan(email: parsedEmail) else { continue }
            let threadKey = message.threadId ?? message.providerMessageId

            let item = YearScanItem(
                mailboxAccountId: mailboxAccountId,
                messagePk: pk,
                providerMessageId: message.providerMessageId,
                threadId: message.threadId,
                subject: message.subject,
                snippet: message.snippet ?? assessment.evidenceQuote,
                score: assessment.score,
                matchedReasons: assessment.matchedReasons
            )

            if let existing = bestByThread[threadKey] {
                if item.score > existing.score {
                    bestByThread[threadKey] = item
                }
            } else {
                bestByThread[threadKey] = item
            }
        }

        return bestByThread.values.sorted { $0.score > $1.score }
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
}
