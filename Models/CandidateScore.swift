import Foundation
import GRDB

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

struct BorderlineItem: Identifiable, Hashable {
    let id: Int64
    let messagePk: Int64
    let mailboxAccountId: String
    let subject: String
    let snippet: String
    let score: Double
    let matchedRuleIds: [String]
    let matchedReasons: [String]
}
