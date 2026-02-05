import Foundation
@preconcurrency import Combine

protocol ObligationExtracting: Sendable {
    func extract(from messages: [MessageRecord], mailboxAccountId: String) async throws -> [ObligationRecord]
    func assess(message: MessageRecord, mailboxAccountId: String) async throws -> RuleAssessment
    func makeObligation(from assessment: RuleAssessment, message: MessageRecord, mailboxAccountId: String, messagePk: Int64) -> ObligationRecord
}

final class ObligationExtractor: ObligationExtracting, @unchecked Sendable {
    private let parser = EmailParser()
    private let ruleEngine: RuleEngine
    private let ruleWeightRepository: RuleWeightRepositorying
    private let candidateScoreRepository: CandidateScoreRepositorying

    init(
        preferences: FilterPreferencesStoring,
        ruleWeightRepository: RuleWeightRepositorying,
        candidateScoreRepository: CandidateScoreRepositorying
    ) {
        self.ruleEngine = RuleEngine(preferences: preferences)
        self.ruleWeightRepository = ruleWeightRepository
        self.candidateScoreRepository = candidateScoreRepository
    }

    func extract(from messages: [MessageRecord], mailboxAccountId: String) async throws -> [ObligationRecord] {
        let multipliers = try await ruleWeightRepository.fetchMultipliers(mailboxAccountId: mailboxAccountId)
        var acceptedByThread: [String: (assessment: RuleAssessment, message: MessageRecord, messagePk: Int64)] = [:]

        for message in messages {
            guard let pk = message.pk else { continue }
            let parsedEmail = parser.parse(message: message)
            let assessment = ruleEngine.assess(email: parsedEmail, weightMultipliers: multipliers)
            let threadKey = message.threadId ?? message.providerMessageId

            if ruleEngine.isAccepted(assessment) {
                if let existing = acceptedByThread[threadKey] {
                    if isPreferred(assessment, over: existing.assessment) {
                        acceptedByThread[threadKey] = (assessment, message, pk)
                    }
                } else {
                    acceptedByThread[threadKey] = (assessment, message, pk)
                }
                try? await candidateScoreRepository.delete(messagePk: pk)
            } else if ruleEngine.isBorderline(assessment) {
                let record = CandidateScoreRecord(
                    messagePk: pk,
                    score: assessment.score,
                    matchedRuleIds: assessment.matchedRuleIds.joined(separator: ","),
                    reasons: assessment.matchedReasons.joined(separator: " | ")
                )
                try await candidateScoreRepository.saveBorderline(record)
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
        let obligationKey = "\(message.providerMessageId)_\(assessment.category.rawValue)"
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
            matchedReasons: assessment.matchedReasons.joined(separator: " | ")
        )
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
}
