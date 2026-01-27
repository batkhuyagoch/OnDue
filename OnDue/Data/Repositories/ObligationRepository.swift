import Foundation

protocol ObligationRepositorying {
    func fetchTopDigest(limit: Int) async throws -> [Obligation]
    func save(_ obligations: [Obligation]) async throws
    func updateStatus(id: UUID, status: ObligationStatus) async throws
}

final class ObligationRepository: ObligationRepositorying {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func fetchTopDigest(limit: Int) async throws -> [Obligation] {
        // TODO: Query local database by status, ordered by deadline, limited to 10.
        return []
    }

    func save(_ obligations: [Obligation]) async throws {
        // TODO: Upsert obligations and evidence lines.
    }

    func updateStatus(id: UUID, status: ObligationStatus) async throws {
        // TODO: Persist status change.
    }
}
