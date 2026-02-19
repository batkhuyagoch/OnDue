import Foundation

// MARK: - Manual Promotion Extension

extension ObligationRepository {
    
    /// Persists a manually promoted obligation from an already-assessed message.
    func promoteManually(
        message: MessageRecord,
        mailboxAccountId: String,
        assessment: RuleAssessment
    ) async throws -> ObligationItem {
        guard let messagePk = message.pk else {
            throw ManualPromotionError.messageMissingPk
        }

        guard let primaryHypothesisId = assessment.decisionContract.primaryHypothesisId,
              !primaryHypothesisId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManualPromotionError.invalidDecisionContract
        }
        let reasonCode = assessment.decisionContract.reasonCode.rawValue
        let policyVersion = assessment.decisionContract.policyVersion
        guard !reasonCode.isEmpty, !policyVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManualPromotionError.invalidDecisionContract
        }

        let domain = (message.fromDomain ?? "unknown").lowercased()
        let ruleKey = assessment.matchedRuleIds.map { $0.lowercased() }.sorted().joined(separator: "|")
        let obligationKey = "\(mailboxAccountId)|\(domain)|\(ruleKey)"
        
        let record = ObligationRecord(
            mailboxAccountId: mailboxAccountId,
            messagePk: messagePk,
            category: assessment.category,
            title: message.subject,
            deadlineAt: assessment.deadline,
            risk: assessment.risk,
            whoOwes: .me,
            confidence: min(1.0, assessment.confidence + 0.3), // Boost confidence for manual promotion
            evidenceQuote: assessment.evidenceQuote,
            obligationKey: obligationKey,
            score: max(assessment.score, 2.0), // Ensure it's above threshold
            matchedRuleIds: assessment.matchedRuleIds.joined(separator: ","),
            matchedSignalTypes: assessment.matchedSignalTypes.map { $0.rawValue }.joined(separator: ","),
            matchedReasons: assessment.matchedReasons.joined(separator: ";"),
            primaryHypothesisId: primaryHypothesisId,
            reasonCode: reasonCode,
            policyVersion: policyVersion,
            repeatCount: 1,
            lastSeenAt: message.internalDate
        )
        
        try await save(record)
        
        return ObligationItem(record: record)
    }
}

enum ManualPromotionError: LocalizedError {
    case messageNotFound
    case messageMissingPk
    case invalidDecisionContract
    
    var errorDescription: String? {
        switch self {
        case .messageNotFound:
            return "Message not found in database"
        case .messageMissingPk:
            return "Message is missing a database identifier"
        case .invalidDecisionContract:
            return "Message could not be promoted because canonical decision metadata is missing"
        }
    }
}

