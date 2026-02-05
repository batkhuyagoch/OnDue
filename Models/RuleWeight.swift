import Foundation
import GRDB

struct RuleWeightRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "rule_weight"

    var id: String
    var mailboxAccountId: String
    var ruleId: String
    var multiplier: Double
    var truePos: Int
    var falsePos: Int
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        mailboxAccountId: String,
        ruleId: String,
        multiplier: Double = 1.0,
        truePos: Int = 0,
        falsePos: Int = 0,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mailboxAccountId = mailboxAccountId
        self.ruleId = ruleId
        self.multiplier = multiplier
        self.truePos = truePos
        self.falsePos = falsePos
        self.updatedAt = updatedAt
    }
}
