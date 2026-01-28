import Foundation
import GRDB

protocol MessageRepositorying: Sendable {
    func save(_ messages: [MessageRecord]) async throws
    func fetchRecent(mailboxAccountId: String, daysBack: Int) async throws -> [MessageRecord]
    func fetchByPk(_ pk: Int64) async throws -> MessageRecord?
    func search(query: String, mailboxAccountId: String, limit: Int) async throws -> [MessageRecord]
}

final class MessageRepository: MessageRepositorying, @unchecked Sendable {
    private let database: Database
    
    init(database: Database) {
        self.database = database
    }
    
    func save(_ messages: [MessageRecord]) async throws {
        try await database.writeAsync { db in
            for var message in messages {
                try message.save(db)
            }
        }
    }
    
    func fetchRecent(mailboxAccountId: String, daysBack: Int) async throws -> [MessageRecord] {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        
        return try await database.readAsync { db in
            try MessageRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .filter(Column("internalDate") >= cutoffDate)
                .filter(Column("isDeleted") == false)
                .order(Column("internalDate").desc)
                .fetchAll(db)
        }
    }
    
    func fetchByPk(_ pk: Int64) async throws -> MessageRecord? {
        try await database.readAsync { db in
            try MessageRecord.fetchOne(db, key: ["pk": pk])
        }
    }
    
    func search(query: String, mailboxAccountId: String, limit: Int) async throws -> [MessageRecord] {
        try await database.readAsync { db in
            try FTS.searchMessages(query: query, mailboxAccountId: mailboxAccountId, in: db, limit: limit)
        }
    }
}
