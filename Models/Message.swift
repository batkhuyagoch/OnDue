import Foundation
import GRDB

struct MessageRecord: Identifiable, Hashable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "message"
    
    var pk: Int64?
    var id: String
    var mailboxAccountId: String
    var providerMessageId: String
    var threadId: String?
    var internalDate: Date
    var fromEmail: String
    var fromName: String?
    var fromDomain: String?
    var subject: String
    var snippet: String?
    var bodyText: String?
    var bodyHtml: String?
    var hasAttachments: Bool
    var attachmentTypes: String?
    var hasPdf: Bool
    var hasCalendar: Bool
    var labelIds: String?
    var isDeleted: Bool
    var ingestedAt: Date
    
    init(
        pk: Int64? = nil,
        id: String = UUID().uuidString,
        mailboxAccountId: String,
        providerMessageId: String,
        threadId: String? = nil,
        internalDate: Date,
        fromEmail: String,
        fromName: String? = nil,
        fromDomain: String? = nil,
        subject: String,
        snippet: String? = nil,
        bodyText: String? = nil,
        bodyHtml: String? = nil,
        hasAttachments: Bool = false,
        attachmentTypes: String? = nil,
        hasPdf: Bool = false,
        hasCalendar: Bool = false,
        labelIds: String? = nil,
        isDeleted: Bool = false,
        ingestedAt: Date = Date()
    ) {
        self.pk = pk
        self.id = id
        self.mailboxAccountId = mailboxAccountId
        self.providerMessageId = providerMessageId
        self.threadId = threadId
        self.internalDate = internalDate
        self.fromEmail = fromEmail
        self.fromName = fromName
        self.fromDomain = fromDomain ?? Self.extractDomain(from: fromEmail)
        self.subject = subject
        self.snippet = snippet
        self.bodyText = bodyText
        self.bodyHtml = bodyHtml
        self.hasAttachments = hasAttachments
        self.attachmentTypes = attachmentTypes
        self.hasPdf = hasPdf
        self.hasCalendar = hasCalendar
        self.labelIds = labelIds
        self.isDeleted = isDeleted
        self.ingestedAt = ingestedAt
    }
    
    private static func extractDomain(from email: String) -> String? {
        guard let atIndex = email.lastIndex(of: "@") else { return nil }
        return String(email[email.index(after: atIndex)...]).lowercased()
    }
    
    // Auto-increment support
    mutating func didInsert(_ inserted: InsertionSuccess) {
        pk = inserted.rowID
    }
}
