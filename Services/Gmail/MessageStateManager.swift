import Foundation
import GRDB

/// Manages message state by reconciling Gmail API data with local user actions.
/// This ensures that user deletions, labels, and dismissals persist across API fetches.
final class MessageStateManager: Sendable {
    private let database: Database
    private let excludedMessageCache = ExcludedMessageIDCache()
    
    init(database: Database = .shared) {
        self.database = database
    }
    
    // MARK: - Recording Actions
    
    /// Records a user action locally (deletion, label, dismissal, etc.)
    func recordAction(messageID: String, action: UserActionRecord.UserActionType, data: String? = nil) async throws {
        let record = UserActionRecord(
            messageID: messageID,
            actionType: action,
            actionData: data
        )
        
        try await database.writeAsync { db in
            try record.insert(db)
        }
        
        AppLog.debug(
            "MessageStateManager.recordAction",
            fields: ["messageID": messageID, "action": action.rawValue]
        )
    }
    
    /// Records a labeled action with labels
    func recordLabels(messageID: String, labels: [String]) async throws {
        let record = UserActionRecord.labeledAction(messageID: messageID, labels: labels)
        try await database.writeAsync { db in
            try record.insert(db)
        }
        
        AppLog.debug(
            "MessageStateManager.recordLabels",
            fields: ["messageID": messageID, "labels": labels.joined(separator: ", ")]
        )
    }
    
    /// Marks an action as synced to Gmail API
    func markSynced(actionID: String) async throws {
        try await database.writeAsync { db in
            try db.execute(
                sql: "UPDATE user_actions SET synced = 1 WHERE id = ?",
                arguments: [actionID]
            )
        }
    }
    
    // MARK: - Querying Actions
    
    /// Gets all actions for a specific message
    func getActions(for messageID: String) async throws -> [UserActionRecord] {
        try await database.readAsync { db in
            try UserActionRecord
                .filter(Column("messageID") == messageID)
                .order(Column("timestamp").desc)
                .fetchAll(db)
        }
    }
    
    /// Gets the latest action for a message
    func getLatestAction(for messageID: String) async throws -> UserActionRecord? {
        try await database.readAsync { db in
            try UserActionRecord.latestAction(for: messageID, db: db)
        }
    }
    
    /// Gets all unsynced actions
    func getUnsyncedActions() async throws -> [UserActionRecord] {
        try await database.readAsync { db in
            try UserActionRecord.unsyncedActions(db: db)
        }
    }
    
    // MARK: - State Reconciliation
    
    /// Gets a set of message IDs that should be excluded (deleted/dismissed/archived)
    func getExcludedMessageIDs() async throws -> Set<String> {
        let excludedTypes: [UserActionRecord.UserActionType] = [
            .deleted,
            .dismissed,
            .archived
        ]
        
        return try await database.readAsync { db in
            try UserActionRecord
                .filter(excludedTypes.map { $0.rawValue }.contains(Column("actionType")))
                .select(Column("messageID"), as: String.self)
                .fetchSet(db)
        }
    }

    /// Cached version of excluded IDs for hot paths that call repeatedly.
    /// - parameter maxAge: Maximum cache age in seconds. Pass 0 to force refresh.
    func getExcludedMessageIDsCached(maxAge: TimeInterval) async throws -> Set<String> {
        try await excludedMessageCache.value(
            maxAge: maxAge,
            loader: { [database] in
                let excludedTypes: [UserActionRecord.UserActionType] = [.deleted, .dismissed, .archived]
                return try await database.readAsync { db in
                    try UserActionRecord
                        .filter(excludedTypes.map { $0.rawValue }.contains(Column("actionType")))
                        .select(Column("messageID"), as: String.self)
                        .fetchSet(db)
                }
            }
        )
    }
    
    /// Filters messages based on local user actions (removes deleted/dismissed messages)
    func filterWithLocalState(_ messages: [GmailMessageSummary]) async throws -> [GmailMessageSummary] {
        let excludedIDs = try await getExcludedMessageIDs()
        
        let filtered = messages.filter { !excludedIDs.contains($0.messageID) }
        
        if filtered.count != messages.count {
            AppLog.debug(
                "MessageStateManager.filterWithLocalState",
                fields: [
                    "original": messages.count,
                    "filtered": filtered.count,
                    "excluded": messages.count - filtered.count
                ]
            )
        }
        
        return filtered
    }
    
    /// Applies local label changes to messages
    func applyLocalLabels(_ messages: [GmailMessageSummary]) async throws -> [GmailMessageSummary] {
        let labelActions = try await database.readAsync { db in
            try UserActionRecord
                .filter(Column("actionType") == UserActionRecord.UserActionType.labeled.rawValue)
                .fetchAll(db)
        }
        
        guard !labelActions.isEmpty else {
            return messages
        }
        
        var messagesDict = Dictionary(uniqueKeysWithValues: messages.map { ($0.messageID, $0) })
        var modifiedCount = 0
        
        for action in labelActions {
            guard let message = messagesDict[action.messageID],
                  let labels = action.labels else {
                continue
            }
            
            // Merge local labels with server labels
            let mergedLabels = Array(Set(message.labelIDs + labels))
            
            messagesDict[action.messageID] = GmailMessageSummary(
                messageID: message.messageID,
                threadID: message.threadID,
                sender: message.sender,
                senderName: message.senderName,
                subject: message.subject,
                snippet: message.snippet,
                receivedAt: message.receivedAt,
                labelIDs: mergedLabels,
                hasAttachments: message.hasAttachments
            )
            modifiedCount += 1
        }
        
        if modifiedCount > 0 {
            AppLog.debug(
                "MessageStateManager.applyLocalLabels",
                fields: ["modified": modifiedCount]
            )
        }
        
        return Array(messagesDict.values)
    }
    
    /// Convenience method that applies all local state transformations
    func reconcileWithLocalState(_ messages: [GmailMessageSummary]) async throws -> [GmailMessageSummary] {
        var reconciled = messages
        reconciled = try await filterWithLocalState(reconciled)
        reconciled = try await applyLocalLabels(reconciled)
        return reconciled
    }
    
    // MARK: - Cleanup
    
    /// Removes actions older than a specified number of days
    func cleanupOldActions(olderThanDays days: Int) async throws {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        
        let deleted = try await database.writeAsync { db in
            try UserActionRecord
                .filter(Column("timestamp") < cutoffDate)
                .filter(Column("synced") == true)
                .deleteAll(db)
        }
        
        if deleted > 0 {
            AppLog.info(
                "MessageStateManager.cleanupOldActions",
                fields: ["deleted": deleted, "cutoffDays": days]
            )
        }
    }
    
    /// Undoes the last action for a message
    func undoLastAction(for messageID: String) async throws {
        try await database.writeAsync { db in
            if let latest = try UserActionRecord.latestAction(for: messageID, db: db) {
                try latest.delete(db)
                AppLog.debug(
                    "MessageStateManager.undoLastAction",
                    fields: ["messageID": messageID, "action": latest.actionType.rawValue]
                )
            }
        }
    }
    
    /// Clears all actions for a message
    func clearActions(for messageID: String) async throws {
        let deleted = try await database.writeAsync { db in
            try UserActionRecord
                .filter(Column("messageID") == messageID)
                .deleteAll(db)
        }
        
        if deleted > 0 {
            AppLog.debug(
                "MessageStateManager.clearActions",
                fields: ["messageID": messageID, "count": deleted]
            )
        }
    }
}

private actor ExcludedMessageIDCache {
    private var cachedIDs: Set<String> = []
    private var updatedAt: Date?

    func value(
        maxAge: TimeInterval,
        loader: @escaping @Sendable () async throws -> Set<String>
    ) async throws -> Set<String> {
        let now = Date()
        if let updatedAt,
           maxAge > 0,
           now.timeIntervalSince(updatedAt) <= maxAge {
            return cachedIDs
        }
        let fresh = try await loader()
        cachedIDs = fresh
        self.updatedAt = now
        return fresh
    }
}
