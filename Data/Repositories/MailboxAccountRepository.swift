import Foundation
import GRDB

protocol MailboxAccountRepositorying: Sendable {
    func getOrCreate(email: String, provider: MailboxAccountRecord.Provider) async throws -> MailboxAccountRecord
    func fetch(byEmail email: String) async throws -> MailboxAccountRecord?
    func fetch(byId id: String) async throws -> MailboxAccountRecord?
    func fetchFirst(provider: MailboxAccountRecord.Provider) async throws -> MailboxAccountRecord?
    func updateSyncStatus(id: String, status: MailboxAccountRecord.SyncStatus, error: String?) async throws
    func updateSyncMetadata(id: String, gmailLastHistoryId: String?, lastFullSyncAt: Date?) async throws
}

final class MailboxAccountRepository: MailboxAccountRepositorying, @unchecked Sendable {
    private let database: Database
    
    init(database: Database) {
        self.database = database
    }
    
    func getOrCreate(email: String, provider: MailboxAccountRecord.Provider) async throws -> MailboxAccountRecord {
        try await database.writeAsync { db in
            if let existing = try MailboxAccountRecord
                .filter(Column("emailAddress") == email)
                .fetchOne(db) {
                return existing
            }
            
            let account = MailboxAccountRecord(
                provider: provider,
                emailAddress: email
            )
            try account.insert(db)
            return account
        }
    }
    
    func fetch(byEmail email: String) async throws -> MailboxAccountRecord? {
        try await database.readAsync { db in
            try MailboxAccountRecord
                .filter(Column("emailAddress") == email)
                .fetchOne(db)
        }
    }

    func fetch(byId id: String) async throws -> MailboxAccountRecord? {
        try await database.readAsync { db in
            try MailboxAccountRecord.fetchOne(db, key: ["id": id])
        }
    }

    func fetchFirst(provider: MailboxAccountRecord.Provider) async throws -> MailboxAccountRecord? {
        try await database.readAsync { db in
            try MailboxAccountRecord
                .filter(Column("provider") == provider.rawValue)
                .order(Column("createdAt").desc)
                .fetchOne(db)
        }
    }
    
    func updateSyncStatus(id: String, status: MailboxAccountRecord.SyncStatus, error: String?) async throws {
        try await database.writeAsync { db in
            try db.execute(
                sql: """
                    UPDATE mailbox_account
                    SET syncStatus = ?, syncError = ?, lastSyncAt = ?
                    WHERE id = ?
                """,
                arguments: [status.rawValue, error, Date(), id]
            )
        }
    }

    func updateSyncMetadata(id: String, gmailLastHistoryId: String?, lastFullSyncAt: Date?) async throws {
        try await database.writeAsync { db in
            try db.execute(
                sql: """
                    UPDATE mailbox_account
                    SET gmailLastHistoryId = ?, lastFullSyncAt = ?
                    WHERE id = ?
                """,
                arguments: [gmailLastHistoryId, lastFullSyncAt, id]
            )
        }
    }
}
