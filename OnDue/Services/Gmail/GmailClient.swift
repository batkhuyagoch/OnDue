import Foundation

struct GmailMessageSummary: Hashable {
    let messageID: String
    let sender: String
    let subject: String
    let snippet: String
    let receivedAt: Date
}

protocol GmailClienting {
    func fetchMessages(daysBack: Int) async throws -> [GmailMessageSummary]
}

final class GmailClient: GmailClienting {
    func fetchMessages(daysBack: Int) async throws -> [GmailMessageSummary] {
        // TODO: Use Gmail API with read-only scope.
        return []
    }
}
