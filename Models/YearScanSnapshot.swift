import Foundation
import GRDB

struct YearScanSnapshot: Hashable {
    let items: [YearScanItem]
    let lastChecked: Date?
    let scannedMessageCount: Int
    let coverageSummary: String
    let isInProgress: Bool
    let statusMessage: String?
    let updatedAt: Date?
}

struct YearScanResultRecord: Identifiable, Hashable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "year_scan_result"

    var id: String
    var mailboxAccountId: String
    var messagePk: Int64
    var providerMessageId: String
    var threadId: String?
    var subject: String
    var snippet: String
    var score: Double
    var matchedReasons: String
    var detectedAt: Date

    init(item: YearScanItem) {
        self.id = item.id
        self.mailboxAccountId = item.mailboxAccountId
        self.messagePk = item.messagePk
        self.providerMessageId = item.providerMessageId
        self.threadId = item.threadId
        self.subject = item.subject
        self.snippet = item.snippet
        self.score = item.score
        self.matchedReasons = item.matchedReasons.joined(separator: " | ")
        self.detectedAt = item.detectedAt
    }

    func toItem() -> YearScanItem {
        let reasons = matchedReasons.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        return YearScanItem(
            mailboxAccountId: mailboxAccountId,
            messagePk: messagePk,
            providerMessageId: providerMessageId,
            threadId: threadId,
            subject: subject,
            snippet: snippet,
            score: score,
            matchedReasons: reasons.map { String($0) },
            detectedAt: detectedAt
        )
    }
}

struct YearScanStateRecord: Identifiable, Hashable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "year_scan_state"

    var id: String
    var lastChecked: Date?
    var scannedMessageCount: Int
    var coverageSummary: String
    var isInProgress: Bool
    var statusMessage: String?
    var updatedAt: Date?
}
