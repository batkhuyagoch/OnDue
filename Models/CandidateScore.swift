import Foundation
import GRDB

/// Deprecated scoring artifact.
/// Retained for legacy cleanup paths only; do not attach new policy-driven logic.
struct CandidateScoreRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "candidate_score"

    var messagePk: Int64
    var score: Double
    var matchedRuleIds: String?
    var reasons: String?
    var rulesVersion: Int
    var createdAt: Date
    var updatedAt: Date?

    var id: Int64 { messagePk }

    init(
        messagePk: Int64,
        score: Double,
        matchedRuleIds: String? = nil,
        reasons: String? = nil,
        rulesVersion: Int = 1,
        createdAt: Date = Date(),
        updatedAt: Date? = nil
    ) {
        self.messagePk = messagePk
        self.score = score
        self.matchedRuleIds = matchedRuleIds
        self.reasons = reasons
        self.rulesVersion = rulesVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

