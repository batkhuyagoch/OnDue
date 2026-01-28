import Foundation
import GRDB

struct MailboxAccountRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "mailbox_account"
    
    var id: String
    var provider: Provider
    var emailAddress: String
    var createdAt: Date
    var lastSyncAt: Date?
    var gmailLastHistoryId: String?
    var lastFullSyncAt: Date?
    var syncStatus: SyncStatus
    var syncError: String?
    
    init(
        id: String = UUID().uuidString,
        provider: Provider = .gmail,
        emailAddress: String,
        createdAt: Date = Date(),
        lastSyncAt: Date? = nil,
        gmailLastHistoryId: String? = nil,
        lastFullSyncAt: Date? = nil,
        syncStatus: SyncStatus = .ok,
        syncError: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.emailAddress = emailAddress
        self.createdAt = createdAt
        self.lastSyncAt = lastSyncAt
        self.gmailLastHistoryId = gmailLastHistoryId
        self.lastFullSyncAt = lastFullSyncAt
        self.syncStatus = syncStatus
        self.syncError = syncError
    }
    
    enum Provider: String, Codable, DatabaseValueConvertible {
        case gmail
    }
    
    enum SyncStatus: String, Codable, DatabaseValueConvertible {
        case ok
        case syncing
        case error
    }
}
