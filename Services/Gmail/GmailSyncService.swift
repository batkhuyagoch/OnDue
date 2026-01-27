import Foundation

protocol GmailSyncServicing {
    func initialSync(daysBack: Int) async throws
}

final class GmailSyncService: GmailSyncServicing {
    private let database: Database
    private let client: GmailClienting
    private let snippetRepository: EmailSnippetRepositorying

    init(database: Database, client: GmailClienting = GmailClient()) {
        self.database = database
        self.client = client
        self.snippetRepository = EmailSnippetRepository(database: database)
    }

    func initialSync(daysBack: Int) async throws {
        let messages = try await client.fetchMessages(daysBack: daysBack)
        let snippets = messages.map {
            EmailSnippet(
                id: UUID(),
                messageID: $0.messageID,
                sender: $0.sender,
                subject: $0.subject,
                snippet: $0.snippet,
                receivedAt: $0.receivedAt
            )
        }
        try await snippetRepository.save(snippets)
    }
}
