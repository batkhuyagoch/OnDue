import Foundation
import GRDB

enum YearScanPhase: String, Codable, Hashable {
    case backfill
    case scanning
}

struct YearScanResumeState: Codable, Hashable {
    var accountIndex: Int
    var monthIndex: Int
    var totalMonths: Int
    var phase: YearScanPhase
    var beforeDate: Date?
    var beforePk: Int64?
    var scannedMessageCount: Int
    var lastStatusMessage: String?
    var consecutiveQuotaHits: Int
    var lastThrottleReason: String? = nil
    var lastKnownMemoryBytes: UInt64? = nil
    var lastKnownThermalState: String? = nil
    var lastKnownBatchSize: Int? = nil
    var configuredRangeMonths: Int? = nil
    var configuredIntensity: String? = nil
}

struct YearScanSnapshot: Hashable {
    let items: [YearScanItem]
    let expectedEventSignals: [ExpectedEventPatternSignal]
    let droppedReasonCounts: [LongScanPromotionReasonCode: Int]
    let lastChecked: Date?
    let lastPaused: Date?
    let scannedMessageCount: Int
    let coverageSummary: String
    let isInProgress: Bool
    let statusMessage: String?
    let updatedAt: Date?
    let resumeState: YearScanResumeState?
    let scanRangeMonths: Int
    let scanIntensity: String
}

struct YearScanStateSnapshot: Hashable {
    let lastChecked: Date?
    let lastPaused: Date?
    let scannedMessageCount: Int
    let coverageSummary: String
    let isInProgress: Bool
    let statusMessage: String?
    let updatedAt: Date?
    let resumeState: YearScanResumeState?
    let scanRangeMonths: Int
    let scanIntensity: String
}

struct ExpectedEventPatternSignal: Hashable {
    let mailboxAccountId: String
    let threadId: String?
    let providerMessageId: String
    let subject: String
    let snippet: String
    let confidence: Double
    let dueDate: Date?
    let reasonCode: LongScanPromotionReasonCode
    let source: LongScanSource
    let detectedAt: Date
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
    var source: String
    var promotionDecision: String
    var promotionReasonCode: String
    var confidence: Double
    var dueDate: Date?
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
        self.source = item.source.rawValue
        self.promotionDecision = item.promotionDecision.rawValue
        self.promotionReasonCode = item.promotionReasonCode.rawValue
        self.confidence = item.confidence
        self.dueDate = item.dueDate
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
            source: LongScanSource(rawValue: source) ?? .scan,
            promotionDecision: LongScanPromotionDecision(rawValue: promotionDecision) ?? .promoted,
            promotionReasonCode: LongScanPromotionReasonCode(rawValue: promotionReasonCode) ?? .promotedActionable,
            confidence: confidence,
            dueDate: dueDate,
            detectedAt: detectedAt
        )
    }

    func toExpectedEventPatternSignal() -> ExpectedEventPatternSignal {
        ExpectedEventPatternSignal(
            mailboxAccountId: mailboxAccountId,
            threadId: threadId,
            providerMessageId: providerMessageId,
            subject: subject,
            snippet: snippet,
            confidence: confidence,
            dueDate: dueDate,
            reasonCode: LongScanPromotionReasonCode(rawValue: promotionReasonCode) ?? .convertedExpectedEvent,
            source: LongScanSource(rawValue: source) ?? .scan,
            detectedAt: detectedAt
        )
    }
}

struct YearScanStateRecord: Identifiable, Hashable, Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "year_scan_state"

    var id: String
    var lastChecked: Date?
    var lastPaused: Date?
    var scannedMessageCount: Int
    var coverageSummary: String
    var isInProgress: Bool
    var statusMessage: String?
    var updatedAt: Date?
    var resumeStateJSON: String?
    var scanRangeMonths: Int
    var scanIntensity: String
}
