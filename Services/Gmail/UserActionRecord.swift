import Foundation
import GRDB

/// Tracks user actions performed on messages locally, allowing us to preserve
/// user state (deletions, labels, dismissals) across Gmail API fetches
struct UserActionRecord: Hashable, Sendable, Identifiable {
    var id: String
    var messageID: String
    var actionType: UserActionType
    var actionData: String?
    var timestamp: Date
    var synced: Bool
    
    enum UserActionType: String, CaseIterable, Sendable {
        case deleted
        case labeled
        case dismissed
        case archived
        case starred
        case snoozed
        case markedDone
        case confirmed
    }
    
    init(id: String = UUID().uuidString,
         messageID: String,
         actionType: UserActionType,
         actionData: String? = nil,
         timestamp: Date = Date(),
         synced: Bool = false) {
        self.id = id
        self.messageID = messageID
        self.actionType = actionType
        self.actionData = actionData
        self.timestamp = timestamp
        self.synced = synced
    }
}

// MARK: - GRDB Integration

extension UserActionRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "user_actions"
    
    // Custom database value conversions for actionType
    enum Columns: String, ColumnExpression {
        case id, messageID, actionType, actionData, timestamp, synced
    }
    
    nonisolated func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.messageID] = messageID
        container[Columns.actionType] = actionType.rawValue
        container[Columns.actionData] = actionData
        container[Columns.timestamp] = timestamp
        container[Columns.synced] = synced
    }
    
    nonisolated init(row: Row) {
        id = row[Columns.id]
        messageID = row[Columns.messageID]
        actionType = UserActionType(rawValue: row[Columns.actionType]) ?? .dismissed
        actionData = row[Columns.actionData]
        timestamp = row[Columns.timestamp]
        synced = row[Columns.synced]
    }
}



// MARK: - Query Helpers

extension UserActionRecord {
    /// Get the most recent action for a message
    static func latestAction(for messageID: String, db: GRDB.Database) throws -> UserActionRecord? {
        try UserActionRecord
            .filter(Column("messageID") == messageID)
            .order(Column("timestamp").desc)
            .fetchOne(db)
    }
    
    /// Get all actions of specific types
    static func actions(ofTypes types: [UserActionType], db: GRDB.Database) throws -> [UserActionRecord] {
        try UserActionRecord
            .filter(types.map { $0.rawValue }.contains(Column("actionType")))
            .fetchAll(db)
    }
    
    /// Get all unsynced actions
    static func unsyncedActions(db: GRDB.Database) throws -> [UserActionRecord] {
        try UserActionRecord
            .filter(Column("synced") == false)
            .order(Column("timestamp").desc)
            .fetchAll(db)
    }
}

// MARK: - Action Data Helpers

extension UserActionRecord {
    /// Decode label data for labeled actions
    var labels: [String]? {
        guard actionType == .labeled,
              let data = actionData?.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode([String].self, from: data)
    }
    
    /// Create a labeled action with labels
    static func labeledAction(messageID: String, labels: [String]) -> UserActionRecord {
        let labelsJSON = try? JSONEncoder().encode(labels)
        let labelsString = labelsJSON.flatMap { String(data: $0, encoding: .utf8) }
        return UserActionRecord(
            messageID: messageID,
            actionType: .labeled,
            actionData: labelsString
        )
    }
}
