import Foundation
import GRDB

protocol ObligationRepositorying: Sendable {
    func fetchTopDigest(limit: Int) async throws -> [ObligationItem]
    func fetchDigest(query: String, limit: Int) async throws -> [ObligationItem]
    func save(_ record: ObligationRecord) async throws
    func save(_ records: [ObligationRecord]) async throws
    func updateStatus(id: String, status: ObligationStatus) async throws
    func snooze(id: String, until: Date) async throws
    func dismiss(id: String) async throws
    func markDone(id: String) async throws
}

final class ObligationRepository: ObligationRepositorying, @unchecked Sendable {
    private let database: Database
    
    init(database: Database) {
        self.database = database
    }
    
    func fetchTopDigest(limit: Int) async throws -> [ObligationItem] {
        try await database.readAsync { db in
            let records = try ObligationRecord
                .filter(Column("status") == ObligationStatus.open.rawValue)
                .order(Column("deadlineAt").ascNullsLast)
                .limit(limit)
                .fetchAll(db)
            
            return records.map { ObligationItem(record: $0) }
        }
    }

    func fetchDigest(query: String, limit: Int) async throws -> [ObligationItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try await fetchTopDigest(limit: limit) }
        let ftsQuery = Self.makeFtsQuery(from: trimmed)
        return try await database.readAsync { db in
            let sql = """
                SELECT o.*
                FROM obligation o
                JOIN message m ON m.pk = o.messagePk
                JOIN message_fts f ON f.rowid = m.pk
                WHERE o.status = ?
                  AND m.isDeleted = 0
                  AND message_fts MATCH ?
                ORDER BY o.deadlineAt IS NULL, o.deadlineAt ASC
                LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [ObligationStatus.open.rawValue, ftsQuery, limit])
            return rows.compactMap { row in
                try? ObligationRecord(row: row)
            }.map { ObligationItem(record: $0) }
        }
    }
    
    func save(_ record: ObligationRecord) async throws {
        try await database.writeAsync { db in
            try record.save(db)
        }
    }

    func save(_ records: [ObligationRecord]) async throws {
        guard !records.isEmpty else { return }
        try await database.writeAsync { db in
            let grouped = Dictionary(grouping: records, by: { $0.mailboxAccountId })
            let maxChunkSize = 400

            for (mailboxAccountId, group) in grouped {
                let obligationKeys = Array(Set(group.map { $0.obligationKey }))
                var existingByKey: [String: (id: String, createdAt: Date)] = [:]

                var start = 0
                while start < obligationKeys.count {
                    let end = min(start + maxChunkSize, obligationKeys.count)
                    let chunk = Array(obligationKeys[start..<end])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let sql = """
                        SELECT obligationKey, id, createdAt
                        FROM obligation
                        WHERE mailboxAccountId = ?
                          AND obligationKey IN (\(placeholders))
                    """
                    var args: [DatabaseValueConvertible] = [mailboxAccountId]
                    args.append(contentsOf: chunk)

                    for row in try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)) {
                        if let obligationKey: String = row["obligationKey"],
                           let id: String = row["id"],
                           let createdAt: Date = row["createdAt"] {
                            existingByKey[obligationKey] = (id: id, createdAt: createdAt)
                        }
                    }

                    start = end
                }

                if !existingByKey.isEmpty {
                    print("📌 ObligationRepository.save: \(mailboxAccountId) found \(existingByKey.count) existing obligations; will update instead of insert")
                }

                for var record in group {
                    if let existing = existingByKey[record.obligationKey] {
                        record.id = existing.id
                        record.createdAt = existing.createdAt
                        record.updatedAt = Date()
                    }
                    try record.save(db)
                }
            }
        }
    }
    
    func updateStatus(id: String, status: ObligationStatus) async throws {
        try await database.writeAsync { db in
            try db.execute(
                sql: """
                    UPDATE obligation
                    SET status = ?, updatedAt = ?
                    WHERE id = ?
                """,
                arguments: [status.rawValue, Date(), id]
            )
        }
    }
    
    func snooze(id: String, until: Date) async throws {
        try await database.writeAsync { db in
            try db.execute(
                sql: """
                    UPDATE obligation
                    SET status = ?, snoozedUntil = ?, updatedAt = ?
                    WHERE id = ?
                """,
                arguments: [ObligationStatus.snoozed.rawValue, until, Date(), id]
            )
        }
    }
    
    func dismiss(id: String) async throws {
        try await database.writeAsync { db in
            try db.execute(
                sql: """
                    UPDATE obligation
                    SET status = ?, resolvedAt = ?, updatedAt = ?
                    WHERE id = ?
                """,
                arguments: [ObligationStatus.dismissed.rawValue, Date(), Date(), id]
            )
        }
    }
    
    func markDone(id: String) async throws {
        try await database.writeAsync { db in
            try db.execute(
                sql: """
                    UPDATE obligation
                    SET status = ?, resolvedAt = ?, updatedAt = ?
                    WHERE id = ?
                """,
                arguments: [ObligationStatus.done.rawValue, Date(), Date(), id]
            )
        }
    }
}

private extension ObligationRepository {
    static func makeFtsQuery(from input: String) -> String {
        let rawTokens = input
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        let tokens = rawTokens.compactMap { token -> String? in
            let cleaned = token.trimmingCharacters(in: .punctuationCharacters.union(.symbols))
            return cleaned.isEmpty ? nil : cleaned
        }

        guard !tokens.isEmpty else { return input }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }
}

// MARK: - Mock Data (for development)

#if DEBUG
extension ObligationRepository {
    /// Returns mock data when database is empty (for UI development)
    static func mockObligations() -> [ObligationItem] {
        let now = Date()
        let calendar = Calendar.current
        
        return [
            ObligationItem(
                id: UUID().uuidString,
                mailboxAccountId: "mock",
                messagePk: 1,
                title: "Submit Q1 budget proposal",
                deadline: calendar.date(byAdding: .day, value: 2, to: now),
                status: .open,
                category: .deadline,
                risk: .high,
                whoOwes: .me,
                confidence: 0.92,
                evidenceQuote: "Please send the Q1 budget proposal by Friday",
                matchedRuleIds: ["deadline_keyword", "date_detected"],
                matchedSignalTypes: ["keyword", "date"],
                matchedReasons: ["Contains a deadline keyword", "Detected a date"],
                snoozedUntil: nil
            ),
            ObligationItem(
                id: UUID().uuidString,
                mailboxAccountId: "mock",
                messagePk: 2,
                title: "Review contract draft",
                deadline: calendar.date(byAdding: .day, value: 3, to: now),
                status: .open,
                category: .request,
                risk: .medium,
                whoOwes: .me,
                confidence: 0.85,
                evidenceQuote: "Could you review the attached contract and send feedback?",
                matchedRuleIds: ["request_keyword", "attachment_present"],
                matchedSignalTypes: ["keyword", "attachment"],
                matchedReasons: ["Explicit request language", "Attachment included"],
                snoozedUntil: nil
            ),
            ObligationItem(
                id: UUID().uuidString,
                mailboxAccountId: "mock",
                messagePk: 3,
                title: "Team sync meeting",
                deadline: calendar.date(byAdding: .day, value: 1, to: now),
                status: .open,
                category: .appointment,
                risk: .low,
                whoOwes: .me,
                confidence: 0.98,
                evidenceQuote: "You're invited: Team Sync - Tomorrow at 2pm",
                matchedRuleIds: ["travel_keyword", "date_detected"],
                matchedSignalTypes: ["keyword", "date"],
                matchedReasons: ["Travel itinerary or booking", "Detected a date"],
                snoozedUntil: nil
            ),
            ObligationItem(
                id: UUID().uuidString,
                mailboxAccountId: "mock",
                messagePk: 4,
                title: "Renew software license",
                deadline: calendar.date(byAdding: .day, value: 12, to: now),
                status: .open,
                category: .deadline,
                risk: .medium,
                whoOwes: .me,
                confidence: 0.88,
                evidenceQuote: "Your license expires on Feb 8. Renew to avoid interruption.",
                matchedRuleIds: ["policy_keyword", "date_detected"],
                matchedSignalTypes: ["keyword", "date"],
                matchedReasons: ["Policy or renewal language", "Detected a date"],
                snoozedUntil: nil
            ),
            ObligationItem(
                id: UUID().uuidString,
                mailboxAccountId: "mock",
                messagePk: 5,
                title: "Waiting for design assets from Sarah",
                deadline: nil,
                status: .open,
                category: .followUp,
                risk: .low,
                whoOwes: .them,
                confidence: 0.75,
                evidenceQuote: "I'll send over the final designs by end of week",
                matchedRuleIds: ["request_keyword"],
                matchedSignalTypes: ["keyword"],
                matchedReasons: ["Explicit request language"],
                snoozedUntil: nil
            ),
            ObligationItem(
                id: UUID().uuidString,
                mailboxAccountId: "mock",
                messagePk: 6,
                title: "Pending approval from Legal",
                deadline: nil,
                status: .open,
                category: .followUp,
                risk: .medium,
                whoOwes: .them,
                confidence: 0.80,
                evidenceQuote: "Legal is reviewing, expect response within 48 hours",
                matchedRuleIds: ["policy_keyword"],
                matchedSignalTypes: ["keyword"],
                matchedReasons: ["Policy or renewal language"],
                snoozedUntil: nil
            ),
        ]
    }
}
#endif
