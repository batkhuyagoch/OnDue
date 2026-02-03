import Foundation
import GRDB

protocol ObligationRepositorying: Sendable {
    func fetchTopDigest(limit: Int) async throws -> [ObligationItem]
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
                title: "Submit Q1 budget proposal",
                deadline: calendar.date(byAdding: .day, value: 2, to: now),
                status: .open,
                category: .deadline,
                risk: .high,
                whoOwes: .me,
                confidence: 0.92,
                evidenceQuote: "Please send the Q1 budget proposal by Friday",
                snoozedUntil: nil
            ),
            ObligationItem(
                id: UUID().uuidString,
                title: "Review contract draft",
                deadline: calendar.date(byAdding: .day, value: 3, to: now),
                status: .open,
                category: .request,
                risk: .medium,
                whoOwes: .me,
                confidence: 0.85,
                evidenceQuote: "Could you review the attached contract and send feedback?",
                snoozedUntil: nil
            ),
            ObligationItem(
                id: UUID().uuidString,
                title: "Team sync meeting",
                deadline: calendar.date(byAdding: .day, value: 1, to: now),
                status: .open,
                category: .appointment,
                risk: .low,
                whoOwes: .me,
                confidence: 0.98,
                evidenceQuote: "You're invited: Team Sync - Tomorrow at 2pm",
                snoozedUntil: nil
            ),
            ObligationItem(
                id: UUID().uuidString,
                title: "Renew software license",
                deadline: calendar.date(byAdding: .day, value: 12, to: now),
                status: .open,
                category: .deadline,
                risk: .medium,
                whoOwes: .me,
                confidence: 0.88,
                evidenceQuote: "Your license expires on Feb 8. Renew to avoid interruption.",
                snoozedUntil: nil
            ),
            ObligationItem(
                id: UUID().uuidString,
                title: "Waiting for design assets from Sarah",
                deadline: nil,
                status: .open,
                category: .followUp,
                risk: .low,
                whoOwes: .them,
                confidence: 0.75,
                evidenceQuote: "I'll send over the final designs by end of week",
                snoozedUntil: nil
            ),
            ObligationItem(
                id: UUID().uuidString,
                title: "Pending approval from Legal",
                deadline: nil,
                status: .open,
                category: .followUp,
                risk: .medium,
                whoOwes: .them,
                confidence: 0.80,
                evidenceQuote: "Legal is reviewing, expect response within 48 hours",
                snoozedUntil: nil
            ),
        ]
    }
}
#endif
