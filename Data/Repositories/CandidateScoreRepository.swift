import Foundation
import GRDB

/// Deprecated candidate scoring repository.
/// Retained only for legacy cleanup deletes; do not attach new policy-driven logic.
protocol CandidateScoreRepositorying: Sendable {
    func delete(messagePk: Int64) async throws
}

final class CandidateScoreRepository: CandidateScoreRepositorying, @unchecked Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func delete(messagePk: Int64) async throws {
        try await database.writeAsync { db in
            _ = try CandidateScoreRecord.deleteOne(db, key: ["messagePk": messagePk])
        }
    }
}
