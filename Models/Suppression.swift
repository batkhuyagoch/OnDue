import Foundation
import GRDB

struct SuppressionRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "suppression"
    
    var id: String
    var mailboxAccountId: String?
    var type: SuppressionType
    var value: String
    var isEnabled: Bool
    var createdAt: Date
    
    init(
        id: String = UUID().uuidString,
        mailboxAccountId: String? = nil,
        type: SuppressionType,
        value: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.mailboxAccountId = mailboxAccountId
        self.type = type
        self.value = value
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }
    
    enum SuppressionType: String, Codable, DatabaseValueConvertible {
        case sender
        case domain
        case subjectPattern = "subject_pattern"
    }
}
