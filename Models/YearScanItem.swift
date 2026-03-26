import Foundation
import GRDB

enum LongScanSource: String, Codable, Hashable, CaseIterable, DatabaseValueConvertible {
    case scan
    case sync
    case capture
}

enum LongScanPromotionDecision: String, Codable, Hashable, CaseIterable, DatabaseValueConvertible {
    case promoted
    case expectedEvent
    case dropped
}

enum LongScanPromotionReasonCode: String, Codable, Hashable, CaseIterable, DatabaseValueConvertible {
    case promotedActionable = "promoted_actionable"
    case convertedExpectedEvent = "converted_expected_event"
    case lowConfidence = "low_confidence"
    case missingDueDate = "missing_due_date"
    case suppressed = "suppressed"
}

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
    let source: LongScanSource
    let promotionDecision: LongScanPromotionDecision
    let promotionReasonCode: LongScanPromotionReasonCode
    let confidence: Double
    let dueDate: Date?
    let deadlineSource: DeadlineSource?
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
        source: LongScanSource = .scan,
        promotionDecision: LongScanPromotionDecision = .promoted,
        promotionReasonCode: LongScanPromotionReasonCode = .promotedActionable,
        confidence: Double = 0.8,
        dueDate: Date? = nil,
        deadlineSource: DeadlineSource? = nil,
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
        self.source = source
        self.promotionDecision = promotionDecision
        self.promotionReasonCode = promotionReasonCode
        self.confidence = confidence
        self.dueDate = dueDate
        self.deadlineSource = deadlineSource
        self.detectedAt = detectedAt
        self.id = "\(mailboxAccountId)_\(messagePk)"
    }

    private var decisionPriority: Int {
        switch promotionDecision {
        case .promoted: return 3
        case .expectedEvent: return 2
        case .dropped: return 1
        }
    }

    func isHigherPriority(than other: YearScanItem) -> Bool {
        if decisionPriority != other.decisionPriority {
            return decisionPriority > other.decisionPriority
        }
        if confidence != other.confidence {
            return confidence > other.confidence
        }
        if score != other.score {
            return score > other.score
        }
        return detectedAt > other.detectedAt
    }
}
