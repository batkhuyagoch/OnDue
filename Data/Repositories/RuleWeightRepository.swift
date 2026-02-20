import Foundation
import GRDB

protocol RuleWeightRepositorying: Sendable {
    func fetchMultipliers(mailboxAccountId: String) async throws -> [String: Double]
    /// Deprecated legacy feedback mutator. Do not use for policy-driven adaptation.
    func applyFeedback(
        mailboxAccountId: String,
        matchedRuleIds: [String],
        action: FeedbackRecord.FeedbackAction
    ) async throws
}

final class RuleWeightRepository: RuleWeightRepositorying, @unchecked Sendable {
    private let database: Database

    private let minMultiplier: Double = 0.4
    private let maxMultiplier: Double = 2.5
    private let growthFactor: Double = 1.1
    private let decayFactor: Double = 0.85
    private let snoozeFactor: Double = 1.03
    private let legalGrowthFactor: Double = 1.25
    private let legalDecayFactor: Double = 0.7
    private let legalSnoozeFactor: Double = 1.07
    private let legalRuleIds: Set<String> = [
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
        "ssa_notice",
        "legal_notice"
    ]

    init(database: Database) {
        self.database = database
    }

    func fetchMultipliers(mailboxAccountId: String) async throws -> [String: Double] {
        try await database.readAsync { db in
            let records = try RuleWeightRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .fetchAll(db)
            return Dictionary(uniqueKeysWithValues: records.map { ($0.ruleId, $0.multiplier) })
        }
    }

    /// Deprecated legacy scoring path. Preserve for backward compatibility only.
    func applyFeedback(
        mailboxAccountId: String,
        matchedRuleIds: [String],
        action: FeedbackRecord.FeedbackAction
    ) async throws {
        guard !matchedRuleIds.isEmpty else { return }
        try await database.writeAsync { db in
            for ruleId in matchedRuleIds {
                let existing = try RuleWeightRecord
                    .filter(Column("mailboxAccountId") == mailboxAccountId)
                    .filter(Column("ruleId") == ruleId)
                    .fetchOne(db)

                var record = existing ?? RuleWeightRecord(mailboxAccountId: mailboxAccountId, ruleId: ruleId)
                let updated = self.updatedMultiplier(from: record.multiplier, action: action, ruleId: ruleId)
                record.multiplier = updated
                record.updatedAt = Date()
                switch action {
                case .accepted:
                    record.truePos += 1
                case .dismissed:
                    record.falsePos += 1
                case .snoozed:
                    record.truePos += 1
                default:
                    break
                }
                try record.save(db)
            }
        }
    }

    private func updatedMultiplier(
        from current: Double,
        action: FeedbackRecord.FeedbackAction,
        ruleId: String
    ) -> Double {
        let isLegal = legalRuleIds.contains(ruleId)
        let next: Double
        switch action {
        case .accepted:
            next = current * (isLegal ? legalGrowthFactor : growthFactor)
        case .dismissed:
            next = current * (isLegal ? legalDecayFactor : decayFactor)
        case .snoozed:
            next = current * (isLegal ? legalSnoozeFactor : snoozeFactor)
        default:
            next = current
        }
        return min(max(next, minMultiplier), maxMultiplier)
    }
}
