import Foundation

struct YearScanItem: Identifiable, Hashable {
    let id: String
    let mailboxAccountId: String
    let messagePk: Int64
    let providerMessageId: String
    let threadId: String?
    let subject: String
    let snippet: String
    let score: Double
    let matchedReasons: [String]
    let detectedAt: Date

    init(
        mailboxAccountId: String,
        messagePk: Int64,
        providerMessageId: String,
        threadId: String?,
        subject: String,
        snippet: String,
        score: Double,
        matchedReasons: [String],
        detectedAt: Date = Date()
    ) {
        self.mailboxAccountId = mailboxAccountId
        self.messagePk = messagePk
        self.providerMessageId = providerMessageId
        self.threadId = threadId
        self.subject = subject
        self.snippet = snippet
        self.score = score
        self.matchedReasons = matchedReasons
        self.detectedAt = detectedAt
        self.id = "\(mailboxAccountId)_\(messagePk)"
    }
}
