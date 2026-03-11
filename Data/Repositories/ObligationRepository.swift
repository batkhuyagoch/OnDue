import Foundation
import GRDB

protocol ObligationRepositorying: Sendable {
    func fetchTopDigest(limit: Int) async throws -> [ObligationItem]
    func fetchDigest(query: String, limit: Int) async throws -> [ObligationItem]
    func save(_ record: ObligationRecord) async throws
    func save(_ records: [ObligationRecord]) async throws
    func updateStatus(id: String, status: ObligationStatus) async throws
    func markReviewed(id: String) async throws
    func snooze(id: String, until: Date) async throws
    func dismiss(id: String) async throws
    func markDone(id: String) async throws
    func dismissBySender(mailboxAccountId: String, sender: String) async throws
    func dismissByDomain(mailboxAccountId: String, domain: String) async throws
    func promoteManually(
        message: MessageRecord,
        mailboxAccountId: String,
        assessment: RuleAssessment
    ) async throws -> ObligationItem
}

final class ObligationRepository: ObligationRepositorying, @unchecked Sendable {
    private let database: Database
    private let projectionRepository: ObligationProjectionRepositorying?
    
    init(database: Database, projectionRepository: ObligationProjectionRepositorying? = nil) {
        self.database = database
        self.projectionRepository = projectionRepository
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
        try record.validateCanonicalDecisionInvariants()
        try await database.writeAsync { db in
            try record.save(db)
            try self.projectionRepository?.upsert(obligation: record, in: db)
        }
    }

    func save(_ records: [ObligationRecord]) async throws {
        guard !records.isEmpty else { return }
        try await database.writeAsync { db in
            let grouped = Dictionary(grouping: records, by: { $0.mailboxAccountId })
            let maxChunkSize = 400

            for (mailboxAccountId, group) in grouped {
                let obligationKeys = Array(Set(group.map { $0.obligationKey }))
                let messagePks = Set(group.map(\.messagePk))
                var existingByKey: [String: (id: String, createdAt: Date, repeatCount: Int, lastSeenAt: Date?, status: ObligationStatus, resolvedAt: Date?, snoozedUntil: Date?)] = [:]
                let primaryThreadIdByMessagePk = try Self.fetchPrimaryThreadIds(messagePks: messagePks, db: db)

                var start = 0
                while start < obligationKeys.count {
                    let end = min(start + maxChunkSize, obligationKeys.count)
                    let chunk = Array(obligationKeys[start..<end])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let sql = """
                        SELECT obligationKey, id, createdAt, repeatCount, lastSeenAt, status, resolvedAt, snoozedUntil
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
                            let repeatCount: Int = row["repeatCount"] ?? 1
                            let lastSeenAt: Date? = row["lastSeenAt"]
                            let statusRaw: String? = row["status"]
                            let status = statusRaw.flatMap { ObligationStatus(rawValue: $0) } ?? .open
                            let resolvedAt: Date? = row["resolvedAt"]
                            let snoozedUntil: Date? = row["snoozedUntil"]
                            existingByKey[obligationKey] = (
                                id: id,
                                createdAt: createdAt,
                                repeatCount: repeatCount,
                                lastSeenAt: lastSeenAt,
                                status: status,
                                resolvedAt: resolvedAt,
                                snoozedUntil: snoozedUntil
                            )
                        }
                    }

                    start = end
                }

                if !existingByKey.isEmpty {
                    let dismissed = existingByKey.values.filter { $0.status == .dismissed || $0.status == .done }.count
                    Logger.info("ObligationRepository.save: \(mailboxAccountId) found \(existingByKey.count) existing obligations (dismissed/done: \(dismissed)); will preserve status")
                }

                let groupedByKey = Dictionary(grouping: group, by: { $0.obligationKey })
                for (key, recordsForKey) in groupedByKey {
                    var record = recordsForKey.max(by: { lhs, rhs in
                        if lhs.score != rhs.score { return lhs.score < rhs.score }
                        let lhsDate = lhs.deadlineAt ?? .distantFuture
                        let rhsDate = rhs.deadlineAt ?? .distantFuture
                        return lhsDate > rhsDate
                    }) ?? recordsForKey[0]

                    let incomingCount = recordsForKey.count
                    let lastSeen = recordsForKey.compactMap(\.lastSeenAt).max()
                    record.repeatCount = incomingCount
                    record.lastSeenAt = lastSeen ?? record.lastSeenAt

                    if let existing = existingByKey[key] {
                        record.id = existing.id
                        record.createdAt = existing.createdAt
                        record.updatedAt = Date()
                        record.repeatCount = existing.repeatCount + incomingCount
                        
                        // Preserve user actions: status, resolvedAt, snoozedUntil
                        record.status = existing.status
                        record.resolvedAt = existing.resolvedAt
                        record.snoozedUntil = existing.snoozedUntil
                        
                        if let existingSeen = existing.lastSeenAt, let newSeen = record.lastSeenAt {
                            record.lastSeenAt = max(existingSeen, newSeen)
                        } else if existing.lastSeenAt != nil {
                            record.lastSeenAt = existing.lastSeenAt
                        }
                    }

                    try record.validateCanonicalDecisionInvariants()
                    try record.save(db)
                    try self.projectionRepository?.upsert(
                        obligation: record,
                        in: db,
                        precomputedPrimaryThreadId: primaryThreadIdByMessagePk[record.messagePk]
                    )
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
            if let record = try? ObligationRecord.fetchOne(db, key: id) {
                try self.projectionRepository?.upsert(obligation: record, in: db)
            }
        }
    }

    func markReviewed(id: String) async throws {
        try await database.writeAsync { db in
            try db.execute(
                sql: """
                    UPDATE obligation_projection
                    SET state = ?, lastActionAt = ?, updatedAt = ?
                    WHERE obligationId = ?
                """,
                arguments: [
                    ObligationLifecycleState.active.rawValue,
                    Date(),
                    Date(),
                    id
                ]
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
            if let record = try? ObligationRecord.fetchOne(db, key: id) {
                try self.projectionRepository?.upsert(obligation: record, in: db)
            }
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
            if let record = try? ObligationRecord.fetchOne(db, key: id) {
                try self.projectionRepository?.upsert(obligation: record, in: db)
            }
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
            if let record = try? ObligationRecord.fetchOne(db, key: id) {
                try self.projectionRepository?.upsert(obligation: record, in: db)
            }
        }
    }

    func dismissBySender(mailboxAccountId: String, sender: String) async throws {
        let normalizedSender = sender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedSender.isEmpty else { return }
        try await database.writeAsync { db in
            try db.execute(
                sql: """
                    UPDATE obligation
                    SET status = ?, resolvedAt = ?, updatedAt = ?
                    WHERE mailboxAccountId = ?
                      AND messagePk IN (
                        SELECT pk FROM message
                        WHERE mailboxAccountId = ?
                          AND LOWER(TRIM(fromEmail)) = ?
                      )
                """,
                arguments: [
                    ObligationStatus.dismissed.rawValue,
                    Date(),
                    Date(),
                    mailboxAccountId,
                    mailboxAccountId,
                    normalizedSender
                ]
            )
            try db.execute(
                sql: """
                    UPDATE obligation_projection
                    SET state = ?, lastActionAt = ?, updatedAt = ?
                    WHERE obligationId IN (
                        SELECT o.id
                        FROM obligation o
                        JOIN message m ON m.pk = o.messagePk
                        WHERE o.mailboxAccountId = ?
                          AND m.mailboxAccountId = ?
                          AND LOWER(TRIM(m.fromEmail)) = ?
                    )
                """,
                arguments: [
                    ObligationLifecycleState.suppressed.rawValue,
                    Date(),
                    Date(),
                    mailboxAccountId,
                    mailboxAccountId,
                    normalizedSender
                ]
            )
        }
    }

    func dismissByDomain(mailboxAccountId: String, domain: String) async throws {
        let normalizedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedDomain.isEmpty else { return }
        try await database.writeAsync { db in
            try db.execute(
                sql: """
                    UPDATE obligation
                    SET status = ?, resolvedAt = ?, updatedAt = ?
                    WHERE mailboxAccountId = ?
                      AND messagePk IN (
                        SELECT pk FROM message
                        WHERE mailboxAccountId = ?
                          AND LOWER(TRIM(fromDomain)) = ?
                      )
                """,
                arguments: [
                    ObligationStatus.dismissed.rawValue,
                    Date(),
                    Date(),
                    mailboxAccountId,
                    mailboxAccountId,
                    normalizedDomain
                ]
            )
            try db.execute(
                sql: """
                    UPDATE obligation_projection
                    SET state = ?, lastActionAt = ?, updatedAt = ?
                    WHERE obligationId IN (
                        SELECT o.id
                        FROM obligation o
                        JOIN message m ON m.pk = o.messagePk
                        WHERE o.mailboxAccountId = ?
                          AND m.mailboxAccountId = ?
                          AND LOWER(TRIM(m.fromDomain)) = ?
                    )
                """,
                arguments: [
                    ObligationLifecycleState.suppressed.rawValue,
                    Date(),
                    Date(),
                    mailboxAccountId,
                    mailboxAccountId,
                    normalizedDomain
                ]
            )
        }
    }
}

private extension ObligationRepository {
    static func fetchPrimaryThreadIds(
        messagePks: Set<Int64>,
        db: GRDB.Database
    ) throws -> [Int64: String] {
        guard !messagePks.isEmpty else { return [:] }
        let ids = Array(messagePks)
        let maxChunkSize = 400
        var start = 0
        var result: [Int64: String] = [:]

        while start < ids.count {
            let end = min(start + maxChunkSize, ids.count)
            let chunk = Array(ids[start..<end])
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT pk, threadId, providerMessageId
                    FROM message
                    WHERE pk IN (\(placeholders))
                """,
                arguments: StatementArguments(chunk)
            )
            for row in rows {
                guard let pk: Int64 = row["pk"] else { continue }
                let threadId: String? = row["threadId"]
                let providerMessageId: String? = row["providerMessageId"]
                if let resolved = threadId ?? providerMessageId {
                    result[pk] = resolved
                }
            }
            start = end
        }
        return result
    }

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
                primaryHypothesisId: ObligationHypothesis.deadlineImplied.rawValue,
                reasonCode: .deadlineMentioned,
                policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
                snoozedUntil: nil,
                repeatCount: 1,
                lastSeenAt: now,
                createdAt: now,
                updatedAt: now
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
                primaryHypothesisId: ObligationHypothesis.userActionRequired.rawValue,
                reasonCode: .directRequestWithoutDeadline,
                policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
                snoozedUntil: nil,
                repeatCount: 1,
                lastSeenAt: now,
                createdAt: now,
                updatedAt: now
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
                primaryHypothesisId: ObligationHypothesis.appointmentActionRequired.rawValue,
                reasonCode: .appointmentActionRequired,
                policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
                snoozedUntil: nil,
                repeatCount: 2,
                lastSeenAt: now,
                createdAt: now,
                updatedAt: now
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
                primaryHypothesisId: ObligationHypothesis.documentExpiration.rawValue,
                reasonCode: .deadlineMentioned,
                policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
                snoozedUntil: nil,
                repeatCount: 1,
                lastSeenAt: now,
                createdAt: now,
                updatedAt: now
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
                primaryHypothesisId: ObligationHypothesis.waitingOnThirdParty.rawValue,
                reasonCode: .waitingOnThirdParty,
                policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
                snoozedUntil: nil,
                repeatCount: 1,
                lastSeenAt: now,
                createdAt: now,
                updatedAt: now
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
                primaryHypothesisId: ObligationHypothesis.waitingOnThirdParty.rawValue,
                reasonCode: .waitingOnThirdParty,
                policyVersion: DecisionPolicyVersion.v2PolicyDriven.rawValue,
                snoozedUntil: nil,
                repeatCount: 1,
                lastSeenAt: now,
                createdAt: now,
                updatedAt: now
            ),
        ]
    }
}
#endif
