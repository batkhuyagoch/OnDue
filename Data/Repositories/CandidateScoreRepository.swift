import Foundation
import GRDB

protocol CandidateScoreRepositorying: Sendable {
    func saveBorderline(_ record: CandidateScoreRecord) async throws
    func delete(messagePk: Int64) async throws
    func fetchBorderline(limit: Int, offset: Int) async throws -> [BorderlineItem]
}

final class CandidateScoreRepository: CandidateScoreRepositorying, @unchecked Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func saveBorderline(_ record: CandidateScoreRecord) async throws {
        try await database.writeAsync { db in
            var mutable = record
            if let existing = try CandidateScoreRecord.fetchOne(db, key: ["messagePk": record.messagePk]) {
                mutable.createdAt = existing.createdAt
                mutable.updatedAt = Date()
            }
            try mutable.save(db)
        }
    }

    func delete(messagePk: Int64) async throws {
        try await database.writeAsync { db in
            _ = try CandidateScoreRecord.deleteOne(db, key: ["messagePk": messagePk])
        }
    }

    func fetchBorderline(limit: Int, offset: Int) async throws -> [BorderlineItem] {
        try await database.readAsync { db in
            let sql = """
                WITH ranked AS (
                    SELECT cs.messagePk, cs.score, cs.matchedRuleIds, cs.reasons,
                           m.mailboxAccountId, m.subject, COALESCE(m.snippet, '') AS snippet,
                           ROW_NUMBER() OVER (
                               PARTITION BY COALESCE(m.threadId, m.providerMessageId)
                               ORDER BY cs.score DESC, cs.messagePk DESC
                           ) AS rn
                    FROM candidate_score cs
                    JOIN message m ON m.pk = cs.messagePk
                    WHERE m.isDeleted = 0
                )
                SELECT messagePk, score, matchedRuleIds, reasons, mailboxAccountId, subject, snippet
                FROM ranked
                WHERE rn = 1
                ORDER BY score DESC, messagePk DESC
                LIMIT ? OFFSET ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [limit, offset])
            return rows.compactMap { row in
                guard let messagePk: Int64 = row["messagePk"],
                      let score: Double = row["score"],
                      let mailboxAccountId: String = row["mailboxAccountId"],
                      let subject: String = row["subject"],
                      let snippet: String = row["snippet"] else { return nil }
                let ruleIds = (row["matchedRuleIds"] as String? ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let reasons = (row["reasons"] as String? ?? "")
                    .split(separator: "|")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                return BorderlineItem(
                    id: messagePk,
                    messagePk: messagePk,
                    mailboxAccountId: mailboxAccountId,
                    subject: subject,
                    snippet: snippet,
                    score: score,
                    matchedRuleIds: ruleIds,
                    matchedReasons: reasons
                )
            }
        }
    }
}
