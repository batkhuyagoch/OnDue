import Foundation

struct EmailSnippet: Identifiable, Hashable {
    let id: UUID
    let messageID: String
    let sender: String
    let subject: String
    let snippet: String
    let receivedAt: Date
}
