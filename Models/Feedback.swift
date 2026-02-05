import Foundation
import GRDB

struct FeedbackRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "feedback"
    
    var id: String
    var mailboxAccountId: String
    var messagePk: Int64?
    var obligationId: String?
    var action: FeedbackAction
    var reason: String?
    var matchedRuleIds: String?
    var createdAt: Date
    
    init(
        id: String = UUID().uuidString,
        mailboxAccountId: String,
        messagePk: Int64? = nil,
        obligationId: String? = nil,
        action: FeedbackAction,
        reason: String? = nil,
        matchedRuleIds: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mailboxAccountId = mailboxAccountId
        self.messagePk = messagePk
        self.obligationId = obligationId
        self.action = action
        self.reason = reason
        self.matchedRuleIds = matchedRuleIds
        self.createdAt = createdAt
    }
    
    enum FeedbackAction: String, Codable, DatabaseValueConvertible {
        case accepted
        case dismissed
        case snoozed
        case ignoreSender = "ignore_sender"
        case ignoreThread = "ignore_thread"
    }
}
