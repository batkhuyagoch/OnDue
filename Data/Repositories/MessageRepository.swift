import Foundation
import GRDB

protocol MessageRepositorying: Sendable {
    func save(_ messages: [MessageRecord]) async throws
    func fetchRecent(mailboxAccountId: String, daysBack: Int) async throws -> [MessageRecord]
    func fetchByPk(_ pk: Int64) async throws -> MessageRecord?
    func fetchProviderMessageIdsWithBodyText(mailboxAccountId: String, providerMessageIds: [String]) async throws -> Set<String>
    func search(query: String, mailboxAccountId: String, limit: Int) async throws -> [MessageRecord]
    func softDeleteOlderThan(mailboxAccountId: String, daysBack: Int) async throws -> Int
    func deleteAll(for mailboxAccountId: String) async throws -> Int
}

final class MessageRepository: MessageRepositorying, @unchecked Sendable {
    private let database: Database
    
    init(database: Database) {
        self.database = database
    }
    
    func save(_ messages: [MessageRecord]) async throws {
        guard !messages.isEmpty else { return }
        try await database.writeAsync { db in
            let grouped = Dictionary(grouping: messages, by: { $0.mailboxAccountId })
            let maxChunkSize = 400
            
            for (mailboxAccountId, group) in grouped {
                let providerIds = Array(Set(group.map { $0.providerMessageId }))
                var existingByProviderId: [String: (pk: Int64, id: String, bodyText: String?, bodyHtml: String?, attachmentTypes: String?, hasPdf: Bool, hasCalendar: Bool)] = [:]
                
                var start = 0
                while start < providerIds.count {
                    let end = min(start + maxChunkSize, providerIds.count)
                    let chunk = Array(providerIds[start..<end])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let sql = """
                        SELECT providerMessageId, pk, id, bodyText, bodyHtml, attachmentTypes, hasPdf, hasCalendar
                        FROM message
                        WHERE mailboxAccountId = ?
                          AND providerMessageId IN (\(placeholders))
                    """
                    var args: [DatabaseValueConvertible] = [mailboxAccountId]
                    args.append(contentsOf: chunk)
                    
                    for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                        if let providerMessageId: String = row["providerMessageId"],
                           let pk: Int64 = row["pk"],
                           let id: String = row["id"] {
                            let bodyText: String? = row["bodyText"]
                            let bodyHtml: String? = row["bodyHtml"]
                            let attachmentTypes: String? = row["attachmentTypes"]
                            let hasPdf: Bool = row["hasPdf"] ?? false
                            let hasCalendar: Bool = row["hasCalendar"] ?? false
                            existingByProviderId[providerMessageId] = (
                                pk: pk,
                                id: id,
                                bodyText: bodyText,
                                bodyHtml: bodyHtml,
                                attachmentTypes: attachmentTypes,
                                hasPdf: hasPdf,
                                hasCalendar: hasCalendar
                            )
                        }
                    }
                    
                    start = end
                }
                
                if !existingByProviderId.isEmpty {
                    print("📧 MessageRepository.save: \(mailboxAccountId) found \(existingByProviderId.count) existing messages; will update instead of insert")
                }
                
                for var message in group {
                    if let existing = existingByProviderId[message.providerMessageId] {
                        message.pk = existing.pk
                        message.id = existing.id
                        if message.bodyText == nil {
                            message.bodyText = existing.bodyText
                        }
                        if message.bodyHtml == nil {
                            message.bodyHtml = existing.bodyHtml
                        }
                        if message.attachmentTypes == nil {
                            message.attachmentTypes = existing.attachmentTypes
                        }
                        if message.hasPdf == false {
                            message.hasPdf = existing.hasPdf
                        }
                        if message.hasCalendar == false {
                            message.hasCalendar = existing.hasCalendar
                        }
                    }
                    try message.save(db)
                }
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

    func fetchProviderMessageIdsWithBodyText(
        mailboxAccountId: String,
        providerMessageIds: [String]
    ) async throws -> Set<String> {
        guard !providerMessageIds.isEmpty else { return [] }
        return try await database.readAsync { db in
            var collected: [String] = []
            let maxChunkSize = 400
            var start = 0
            while start < providerMessageIds.count {
                let end = min(start + maxChunkSize, providerMessageIds.count)
                let chunk = Array(providerMessageIds[start..<end])
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                let sql = """
                    SELECT providerMessageId
                    FROM message
                    WHERE mailboxAccountId = ?
                      AND providerMessageId IN (\(placeholders))
                      AND bodyText IS NOT NULL
                """
                var args: [DatabaseValueConvertible] = [mailboxAccountId]
                args.append(contentsOf: chunk)
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                collected.append(contentsOf: rows.compactMap { $0["providerMessageId"] as? String })
                start = end
            }
            return Set(collected)
        }
    }
    
    func search(query: String, mailboxAccountId: String, limit: Int) async throws -> [MessageRecord] {
        try await database.readAsync { db in
            try FTS.searchMessages(query: query, mailboxAccountId: mailboxAccountId, in: db, limit: limit)
        }
    }

    func softDeleteOlderThan(mailboxAccountId: String, daysBack: Int) async throws -> Int {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        return try await database.writeAsync { db in
            try MessageRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .filter(Column("internalDate") < cutoffDate)
                .updateAll(db, Column("isDeleted").set(to: true))
        }
    }

    func deleteAll(for mailboxAccountId: String) async throws -> Int {
        try await database.writeAsync { db in
            try MessageRecord
                .filter(Column("mailboxAccountId") == mailboxAccountId)
                .deleteAll(db)
        }
    }
}
