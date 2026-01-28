import Foundation
import GRDB

protocol MailboxAccountRepositorying: Sendable {
    func getOrCreate(email: String, provider: MailboxAccountRecord.Provider) async throws -> MailboxAccountRecord
    func fetch(byEmail email: String) async throws -> MailboxAccountRecord?
    func updateSyncStatus(id: String, status: MailboxAccountRecord.SyncStatus, error: String?) async throws
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
}
