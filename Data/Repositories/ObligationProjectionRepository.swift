import Foundation
import GRDB

protocol ObligationProjectionRepositorying: Sendable {
    func fetchItems(lens: ObligationLens, query: String, limit: Int) async throws -> [ObligationListItem]
    func upsert(obligation: ObligationRecord, in db: GRDB.Database) throws
}

enum ObligationLens: String, CaseIterable, Identifiable {
    case active
    case needsReview
    case snoozed
    case resolved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: "Active"
        case .needsReview: "Needs Review"
        case .snoozed: "Snoozed"
        case .resolved: "Resolved"
        }
    }
}

enum ObligationGrouping: String, CaseIterable, Identifiable {
    case dueDate
    case detectionDate
    case sourceThread

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dueDate: "By Due Date"
        case .detectionDate: "By Detection Date"
        case .sourceThread: "By Source Thread"
        }
    }
}

final class ObligationProjectionRepository: ObligationProjectionRepositorying, @unchecked Sendable {
    private let database: Database
    private let needsReviewThreshold = 0.6

    init(database: Database) {
        self.database = database
    }

    func fetchItems(lens: ObligationLens, query: String, limit: Int) async throws -> [ObligationListItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let states = lensStates(for: lens)
        return try await database.readAsync { db in
            var sql = """
                SELECT o.*, p.state AS projectionState, p.dueBucket AS projectionDueBucket,
                       p.primaryThreadId AS projectionThreadId, p.lastActionAt AS projectionLastActionAt
                FROM obligation_projection p
                JOIN obligation o ON o.id = p.obligationId
                JOIN message m ON m.pk = o.messagePk
            """
            var arguments: [DatabaseValueConvertible] = []

            if !trimmed.isEmpty {
                sql += " JOIN message_fts f ON f.rowid = m.pk"
            }

            let placeholders = states.map { _ in "?" }.joined(separator: ",")
            sql += """
                WHERE p.state IN (\(placeholders))
                  AND m.isDeleted = 0
            """
            arguments.append(contentsOf: states.map(\.rawValue))

            if !trimmed.isEmpty {
                sql += " AND message_fts MATCH ?"
                arguments.append(Self.makeFtsQuery(from: trimmed))
            }

            sql += " LIMIT ?"
            arguments.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))
            return rows.compactMap { row in
                guard let record = try? ObligationRecord(row: row),
                      let stateRaw: String = row["projectionState"],
                      let state = ObligationLifecycleState(rawValue: stateRaw),
                      let dueBucketRaw: String = row["projectionDueBucket"],
                      let dueBucket = ObligationDueBucket(rawValue: dueBucketRaw) else {
                    return nil
                }

                let primaryThreadId: String? = row["projectionThreadId"]
                let lastActionAt: Date? = row["projectionLastActionAt"]
                return ObligationListItem(
                    obligation: ObligationItem(record: record),
                    state: state,
                    dueBucket: dueBucket,
                    primaryThreadId: primaryThreadId,
                    lastActionAt: lastActionAt
                )
            }
        }
    }

    func upsert(obligation: ObligationRecord, in db: GRDB.Database) throws {
        let primaryThreadId = try fetchPrimaryThreadId(messagePk: obligation.messagePk, db: db)
        let state = resolveState(for: obligation)
        let dueBucket = resolveDueBucket(for: obligation)

        var record = ObligationProjectionRecord(
            obligationId: obligation.id,
            state: state,
            confidence: obligation.confidence,
            dueDate: obligation.deadlineAt,
            dueBucket: dueBucket,
            primaryThreadId: primaryThreadId,
            lastActionAt: obligation.updatedAt,
            reasonCode: obligation.reasonCode,
            policyVersion: obligation.policyVersion,
            updatedAt: Date()
        )
        try record.save(db)
    }

    private func resolveState(for obligation: ObligationRecord) -> ObligationLifecycleState {
        switch obligation.status {
        case .dismissed:
            return .suppressed
        case .done:
            return .resolved
        case .snoozed:
            return .snoozed
        case .open:
            if let deadline = obligation.deadlineAt,
               deadline < Calendar.current.startOfDay(for: Date()) {
                return .overdue
            }
            if obligation.confidence < needsReviewThreshold {
                return .needsReview
            }
            return .active
        }
    }

    private func resolveDueBucket(for obligation: ObligationRecord) -> ObligationDueBucket {
        guard let deadline = obligation.deadlineAt else { return .noDueDate }
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        if deadline < startOfToday { return .overdue }
        if Calendar.current.isDateInToday(deadline) { return .today }
        let daysUntil = Calendar.current.dateComponents([.day], from: now, to: deadline).day ?? 0
        if daysUntil <= 3 { return .next3Days }
        if daysUntil <= 7 { return .next7Days }
        return .later
    }

    private func lensStates(for lens: ObligationLens) -> [ObligationLifecycleState] {
        switch lens {
        case .active:
            return [.active, .overdue]
        case .needsReview:
            return [.needsReview]
        case .snoozed:
            return [.snoozed]
        case .resolved:
            // Only completed obligations appear in Resolved.
            // Suppressed (not-an-obligation) items stay out of this lens.
            return [.resolved]
        }
    }

    private func fetchPrimaryThreadId(messagePk: Int64, db: GRDB.Database) throws -> String? {
        let row = try Row.fetchOne(
            db,
            sql: "SELECT threadId, providerMessageId FROM message WHERE pk = ?",
            arguments: [messagePk]
        )
        guard let row else { return nil }
        let threadId: String? = row["threadId"]
        let providerMessageId: String? = row["providerMessageId"]
        return threadId ?? providerMessageId
    }
}

private extension ObligationProjectionRepository {
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
