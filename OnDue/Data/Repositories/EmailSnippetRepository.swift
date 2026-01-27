import Foundation

protocol EmailSnippetRepositorying {
    func save(_ snippets: [EmailSnippet]) async throws
    func fetchRecent(daysBack: Int) async throws -> [EmailSnippet]
}

final class EmailSnippetRepository: EmailSnippetRepositorying {
    private let database: Database

    init(database: Database) {
        self.database = database
    }

    func save(_ snippets: [EmailSnippet]) async throws {
        // TODO: Persist new snippets, dedupe by message ID.
    }

    func fetchRecent(daysBack: Int) async throws -> [EmailSnippet] {
        // TODO: Query local database for recent snippets.
        return []
    }
}
