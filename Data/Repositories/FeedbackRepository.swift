import Foundation
import GRDB

protocol FeedbackRepositorying: Sendable {
    func save(_ record: FeedbackRecord) async throws
}

final class FeedbackRepository: FeedbackRepositorying, @unchecked Sendable {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func save(_ record: FeedbackRecord) async throws {
        try await database.writeAsync { db in
            try record.save(db)
        }
    }
}
