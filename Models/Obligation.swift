import Foundation
import GRDB

// MARK: - Obligation Record (Database)

struct ObligationRecord: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "obligation"
    
    var id: String
    var mailboxAccountId: String
    var messagePk: Int64
    var status: ObligationStatus
    var category: ObligationCategory
    var title: String
    var deadlineAt: Date?
    var risk: ObligationRisk
    var whoOwes: WhoOwes
    var confidence: Double
    var evidenceQuote: String
    var obligationKey: String
    var snoozedUntil: Date?
    var resolvedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    
    init(
        id: String = UUID().uuidString,
        mailboxAccountId: String,
        messagePk: Int64,
        status: ObligationStatus = .open,
        category: ObligationCategory,
        title: String,
        deadlineAt: Date? = nil,
        risk: ObligationRisk = .medium,
        whoOwes: WhoOwes = .unknown,
        confidence: Double = 0.0,
        evidenceQuote: String,
        obligationKey: String,
        snoozedUntil: Date? = nil,
        resolvedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mailboxAccountId = mailboxAccountId
        self.messagePk = messagePk
        self.status = status
        self.category = category
        self.title = title
        self.deadlineAt = deadlineAt
        self.risk = risk
        self.whoOwes = whoOwes
        self.confidence = confidence
        self.evidenceQuote = evidenceQuote
        self.obligationKey = obligationKey
        self.snoozedUntil = snoozedUntil
        self.resolvedAt = resolvedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

// MARK: - Enums

enum ObligationStatus: String, Codable, CaseIterable, DatabaseValueConvertible {
    case open
    case snoozed
    case done
    case dismissed
}

enum ObligationCategory: String, Codable, CaseIterable, DatabaseValueConvertible {
    case deadline
    case request
    case appointment
    case followUp
    case payment
    case other
}

enum ObligationRisk: String, Codable, CaseIterable, DatabaseValueConvertible {
    case high
    case medium
    case low
}

enum WhoOwes: String, Codable, CaseIterable, DatabaseValueConvertible {
    case me
    case them
    case unknown
}

// MARK: - View Model (UI)

struct ObligationItem: Identifiable, Hashable {
    let id: String
    let title: String
    let deadline: Date?
    let status: ObligationStatus
    let category: ObligationCategory
    let risk: ObligationRisk
    let whoOwes: WhoOwes
    let confidence: Double
    let evidenceQuote: String
    let snoozedUntil: Date?
    
    /// Computed section for digest grouping
    var digestSection: DigestSectionType {
        switch status {
        case .snoozed:
            return .snoozed
        case .done, .dismissed:
            return .resolved
        case .open:
            switch whoOwes {
            case .them:
                return .waitingOn
            case .me, .unknown:
                if let deadline = deadline {
                    let daysUntil = Calendar.current.dateComponents([.day], from: Date(), to: deadline).day ?? 0
                    return daysUntil <= 7 ? .thisWeek : .upcoming
                }
                return .upcoming
            }
        }
    }
    
    enum DigestSectionType {
        case thisWeek
        case upcoming
        case waitingOn
        case snoozed
        case resolved
    }
}

// MARK: - Record to View Model

extension ObligationItem {
    init(record: ObligationRecord) {
        self.id = record.id
        self.title = record.title
        self.deadline = record.deadlineAt
        self.status = record.status
        self.category = record.category
        self.risk = record.risk
        self.whoOwes = record.whoOwes
        self.confidence = record.confidence
        self.evidenceQuote = record.evidenceQuote
        self.snoozedUntil = record.snoozedUntil
    }
}
