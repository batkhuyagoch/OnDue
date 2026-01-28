import Foundation

protocol GmailSyncServicing: Sendable {
    func initialSync(mailboxAccountId: String, daysBack: Int) async throws
}

final class GmailSyncService: GmailSyncServicing, @unchecked Sendable {
    private let database: Database
    private let client: GmailClienting
    private let messageRepository: MessageRepositorying
    
    init(database: Database, client: GmailClienting = GmailClient()) {
        self.database = database
        self.client = client
        self.messageRepository = MessageRepository(database: database)
    }
    
    func initialSync(mailboxAccountId: String, daysBack: Int) async throws {
        let summaries = try await client.fetchMessages(daysBack: daysBack)
        
        let messages = summaries.map { summary in
            MessageRecord(
                mailboxAccountId: mailboxAccountId,
                providerMessageId: summary.messageID,
                threadId: summary.threadID,
                internalDate: summary.receivedAt,
                fromEmail: summary.sender,
                fromName: summary.senderName,
                subject: summary.subject,
                snippet: summary.snippet,
                hasAttachments: summary.hasAttachments,
                labelIds: summary.labelIDs.joined(separator: ",")
            )
        }
        
        try await messageRepository.save(messages)
    }
}
