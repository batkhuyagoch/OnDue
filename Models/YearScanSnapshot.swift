import Foundation
import GRDB

enum YearScanPhase: String, Codable, Hashable {
    case backfill
    case scanning
}

struct YearScanMonthSummary: Codable, Hashable, Identifiable {
    var id: String { monthLabel }
    var monthLabel: String
    var monthIndex: Int
    var messagesScanned: Int
    var promotedCount: Int
    var expectedCount: Int
    var droppedCount: Int
    var isInProgress: Bool
    var completedAt: Date?
}

struct ScanDiagnostics: Codable, Hashable {
    var lastStatusMessage: String?
    var lastThrottleReason: String?
    var lastKnownMemoryBytes: UInt64?
    var lastKnownThermalState: String?
    var lastKnownBatchSize: Int?
    var configuredRangeMonths: Int?
    var configuredIntensity: String?
    var currentMonthLabel: String?
    var currentPage: Int?
}

struct YearScanResumeState: Codable, Hashable {
    var accountIndex: Int
    var monthIndex: Int
    var totalMonths: Int
    var phase: YearScanPhase
    var beforeDate: Date?
    var beforePk: Int64?
    var scannedMessageCount: Int
    var consecutiveQuotaHits: Int
    var monthSummaries: [YearScanMonthSummary]?
    var diagnostics: ScanDiagnostics?

    var lastStatusMessage: String? {
        get { diagnostics?.lastStatusMessage }
        set {
            if diagnostics == nil { diagnostics = ScanDiagnostics() }
            diagnostics?.lastStatusMessage = newValue
        }
    }
    var lastThrottleReason: String? { diagnostics?.lastThrottleReason }
    var lastKnownMemoryBytes: UInt64? { diagnostics?.lastKnownMemoryBytes }
    var lastKnownThermalState: String? { diagnostics?.lastKnownThermalState }
    var lastKnownBatchSize: Int? { diagnostics?.lastKnownBatchSize }
    var configuredRangeMonths: Int? { diagnostics?.configuredRangeMonths }
    var configuredIntensity: String? { diagnostics?.configuredIntensity }
    var currentMonthLabel: String? { diagnostics?.currentMonthLabel }
    var currentPage: Int? { diagnostics?.currentPage }

    private enum CodingKeys: String, CodingKey {
        case accountIndex, monthIndex, totalMonths, phase, beforeDate, beforePk
        case scannedMessageCount, consecutiveQuotaHits, monthSummaries, diagnostics
        // Legacy flat keys for backward-compatible decoding
        case lastStatusMessage, lastThrottleReason, lastKnownMemoryBytes
        case lastKnownThermalState, lastKnownBatchSize, configuredRangeMonths
        case configuredIntensity, currentMonthLabel, currentPage
    }

    init(
        accountIndex: Int,
        monthIndex: Int,
        totalMonths: Int,
        phase: YearScanPhase,
        beforeDate: Date? = nil,
        beforePk: Int64? = nil,
        scannedMessageCount: Int,
        lastStatusMessage: String? = nil,
        consecutiveQuotaHits: Int,
        lastThrottleReason: String? = nil,
        lastKnownMemoryBytes: UInt64? = nil,
        lastKnownThermalState: String? = nil,
        lastKnownBatchSize: Int? = nil,
        configuredRangeMonths: Int? = nil,
        configuredIntensity: String? = nil,
        currentMonthLabel: String? = nil,
        currentPage: Int? = nil,
        monthSummaries: [YearScanMonthSummary]? = nil
    ) {
        self.accountIndex = accountIndex
        self.monthIndex = monthIndex
        self.totalMonths = totalMonths
        self.phase = phase
        self.beforeDate = beforeDate
        self.beforePk = beforePk
        self.scannedMessageCount = scannedMessageCount
        self.consecutiveQuotaHits = consecutiveQuotaHits
        self.monthSummaries = monthSummaries
        let hasDiag = lastStatusMessage != nil || lastThrottleReason != nil
            || lastKnownMemoryBytes != nil || lastKnownThermalState != nil
            || lastKnownBatchSize != nil || configuredRangeMonths != nil
            || configuredIntensity != nil || currentMonthLabel != nil || currentPage != nil
        self.diagnostics = hasDiag ? ScanDiagnostics(
            lastStatusMessage: lastStatusMessage,
            lastThrottleReason: lastThrottleReason,
            lastKnownMemoryBytes: lastKnownMemoryBytes,
            lastKnownThermalState: lastKnownThermalState,
            lastKnownBatchSize: lastKnownBatchSize,
            configuredRangeMonths: configuredRangeMonths,
            configuredIntensity: configuredIntensity,
            currentMonthLabel: currentMonthLabel,
            currentPage: currentPage
        ) : nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountIndex = try container.decode(Int.self, forKey: .accountIndex)
        monthIndex = try container.decode(Int.self, forKey: .monthIndex)
        totalMonths = try container.decode(Int.self, forKey: .totalMonths)
        phase = try container.decode(YearScanPhase.self, forKey: .phase)
        beforeDate = try container.decodeIfPresent(Date.self, forKey: .beforeDate)
        beforePk = try container.decodeIfPresent(Int64.self, forKey: .beforePk)
        scannedMessageCount = try container.decode(Int.self, forKey: .scannedMessageCount)
        consecutiveQuotaHits = try container.decode(Int.self, forKey: .consecutiveQuotaHits)
        monthSummaries = try container.decodeIfPresent([YearScanMonthSummary].self, forKey: .monthSummaries)

        if let nested = try container.decodeIfPresent(ScanDiagnostics.self, forKey: .diagnostics) {
            diagnostics = nested
        } else {
            let msg = try container.decodeIfPresent(String.self, forKey: .lastStatusMessage)
            let throttle = try container.decodeIfPresent(String.self, forKey: .lastThrottleReason)
            let mem = try container.decodeIfPresent(UInt64.self, forKey: .lastKnownMemoryBytes)
            let thermal = try container.decodeIfPresent(String.self, forKey: .lastKnownThermalState)
            let batch = try container.decodeIfPresent(Int.self, forKey: .lastKnownBatchSize)
            let range = try container.decodeIfPresent(Int.self, forKey: .configuredRangeMonths)
            let intensity = try container.decodeIfPresent(String.self, forKey: .configuredIntensity)
            let label = try container.decodeIfPresent(String.self, forKey: .currentMonthLabel)
            let page = try container.decodeIfPresent(Int.self, forKey: .currentPage)
            let hasDiag = msg != nil || throttle != nil || mem != nil || thermal != nil
                || batch != nil || range != nil || intensity != nil || label != nil || page != nil
            diagnostics = hasDiag ? ScanDiagnostics(
                lastStatusMessage: msg,
                lastThrottleReason: throttle,
                lastKnownMemoryBytes: mem,
                lastKnownThermalState: thermal,
                lastKnownBatchSize: batch,
                configuredRangeMonths: range,
                configuredIntensity: intensity,
                currentMonthLabel: label,
                currentPage: page
            ) : nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountIndex, forKey: .accountIndex)
        try container.encode(monthIndex, forKey: .monthIndex)
        try container.encode(totalMonths, forKey: .totalMonths)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(beforeDate, forKey: .beforeDate)
        try container.encodeIfPresent(beforePk, forKey: .beforePk)
        try container.encode(scannedMessageCount, forKey: .scannedMessageCount)
        try container.encode(consecutiveQuotaHits, forKey: .consecutiveQuotaHits)
        try container.encodeIfPresent(monthSummaries, forKey: .monthSummaries)
        try container.encodeIfPresent(diagnostics, forKey: .diagnostics)
    }
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
