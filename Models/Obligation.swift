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
    var score: Double
    var matchedRuleIds: String
    var matchedSignalTypes: String
    var matchedReasons: String
    var primaryHypothesisId: String?
    var reasonCode: String?
    var policyVersion: String?
    var snoozedUntil: Date?
    var resolvedAt: Date?
    var repeatCount: Int
    var lastSeenAt: Date?
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
        score: Double = 0.0,
        matchedRuleIds: String = "",
        matchedSignalTypes: String = "",
        matchedReasons: String = "",
        primaryHypothesisId: String? = nil,
        reasonCode: String? = nil,
        policyVersion: String? = nil,
        snoozedUntil: Date? = nil,
        resolvedAt: Date? = nil,
        repeatCount: Int = 1,
        lastSeenAt: Date? = nil,
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
        self.score = score
        self.matchedRuleIds = matchedRuleIds
        self.matchedSignalTypes = matchedSignalTypes
        self.matchedReasons = matchedReasons
        self.primaryHypothesisId = primaryHypothesisId
        self.reasonCode = reasonCode
        self.policyVersion = policyVersion
        self.snoozedUntil = snoozedUntil
        self.resolvedAt = resolvedAt
        self.repeatCount = repeatCount
        self.lastSeenAt = lastSeenAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

extension ObligationRecord {
    enum CanonicalDecisionInvariantError: Error {
        case missingPrimaryHypothesisId
        case missingReasonCode
        case missingPolicyVersion
    }

    func validateCanonicalDecisionInvariants() throws {
        guard let primaryHypothesisId, !primaryHypothesisId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CanonicalDecisionInvariantError.missingPrimaryHypothesisId
        }
        guard let reasonCode, !reasonCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CanonicalDecisionInvariantError.missingReasonCode
        }
        guard let policyVersion, !policyVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CanonicalDecisionInvariantError.missingPolicyVersion
        }
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
    case document
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
    let mailboxAccountId: String
    let messagePk: Int64
    let title: String
    let deadline: Date?
    let status: ObligationStatus
    let category: ObligationCategory
    let risk: ObligationRisk
    let whoOwes: WhoOwes
    let confidence: Double
    let evidenceQuote: String
    let matchedRuleIds: [String]
    let matchedSignalTypes: [String]
    let matchedReasons: [String]
    let primaryHypothesisId: String?
    let reasonCode: ReasonCode
    let policyVersion: String
    let snoozedUntil: Date?
    let repeatCount: Int
    let lastSeenAt: Date?
    let createdAt: Date
    let updatedAt: Date
    
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
                    let now = Date()
                    let daysUntil = Calendar.current.dateComponents([.day], from: now, to: deadline).day ?? 0
                    if daysUntil < 0 {
                        return .overdue
                    }
                    return daysUntil <= 7 ? .thisWeek : .upcoming
                }
                return .upcoming
            }
        }
    }

    var urgencyRank: Int {
        guard let deadline = deadline else { return 5 }
        let now = Date()
        let startOfToday = Calendar.current.startOfDay(for: now)
        if deadline < startOfToday { return 0 }
        if Calendar.current.isDateInToday(deadline) { return 1 }
        let daysUntil = Calendar.current.dateComponents([.day], from: now, to: deadline).day ?? 0
        if daysUntil <= 3 { return 2 }
        if daysUntil <= 7 { return 3 }
        return 4
    }
    
    enum DigestSectionType {
        case overdue
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
        self.mailboxAccountId = record.mailboxAccountId
        self.messagePk = record.messagePk
        self.title = record.title
        self.deadline = record.deadlineAt
        self.status = record.status
        self.category = record.category
        self.risk = record.risk
        self.whoOwes = record.whoOwes
        self.confidence = record.confidence
        self.evidenceQuote = record.evidenceQuote
        self.matchedRuleIds = record.matchedRuleIds
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.matchedSignalTypes = record.matchedSignalTypes
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        self.matchedReasons = record.matchedReasons
            .split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard let primaryHypothesisId = record.primaryHypothesisId,
              !primaryHypothesisId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preconditionFailure("ObligationItem requires non-empty primaryHypothesisId for canonical decision integrity.")
        }
        self.primaryHypothesisId = primaryHypothesisId
        guard let code = record.reasonCode,
              let parsed = ReasonCode(rawValue: code) else {
            preconditionFailure("ObligationItem requires valid reasonCode for canonical decision integrity.")
        }
        self.reasonCode = parsed
        guard let policyVersion = record.policyVersion,
              !policyVersion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            preconditionFailure("ObligationItem requires non-empty policyVersion for canonical decision integrity.")
        }
        self.policyVersion = policyVersion
        self.snoozedUntil = record.snoozedUntil
        self.repeatCount = record.repeatCount
        self.lastSeenAt = record.lastSeenAt
        self.createdAt = record.createdAt
        self.updatedAt = record.updatedAt
    }
}
