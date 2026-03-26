import Foundation
import os

struct YearScanRunResult {
    let items: [YearScanItem]
    let scannedMessageCount: Int
    let resumeState: YearScanResumeState?
    let telemetry: YearScanRunTelemetry
}

struct YearScanRunTelemetry {
    let stopReason: String
    let elapsedSeconds: Double
    let peakMemoryMB: UInt64
    let pagesScanned: Int
    let effectiveBatchSize: Int
    let minBatchSize: Int
    let maxBatchSize: Int
}

struct YearScanPartialUpdate {
    let items: [YearScanItem]
    let scannedMessageCount: Int
    let resumeState: YearScanResumeState
    let statusMessage: String
}

struct YearScanQuotaStoppedError: Error {
    let lastCompletedMonthIndex: Int
    let totalMonths: Int
    let resumeState: YearScanResumeState
}

enum YearScanRunner {
    static let coverageSummary = "Inbox, excluding promotions & social"
    private static let pageSize = 500
    
    
    
    private static let memorySoftWarningBytes: UInt64 = 450_000_000
    private static let memoryHighPressureBytes: UInt64 = 550_000_000
    private static let memoryHardPressureBytes: UInt64 = 700_000_000
    private static let hardPauseSeconds: UInt64 = 5
    private static let hardPauseCooldownSeconds: TimeInterval = 20
    private static let recoveryPagesAfterHardPause = 6

    private static let signposter = OSSignposter(subsystem: "com.ondue.yearscan", category: "ScanPipeline")
    
    enum ThrottleReason: String {
        case thermal
        case memory
        case lowPower
        case recovery
    }
    
    struct RuntimeSnapshot: Equatable {
        let thermalState: ProcessInfo.ThermalState
        let isLowPowerModeEnabled: Bool
        let memoryUsedBytes: UInt64
    }
    
    struct ThrottleState {
        var lastHardPauseAt: Date?
        var recoveryPagesRemaining: Int = 0
        var lastReason: ThrottleReason?
    }
    
    struct ThrottleDecision: Equatable {
        let batchSize: Int
        let pauseSeconds: UInt64
        let reason: ThrottleReason?
        let userFacingStatus: String?
        
        var shouldPause: Bool { pauseSeconds > 0 }
    }

    struct RunConfiguration: Equatable, Sendable {
        let rangeMonths: Int
        let intensity: CoverageScanIntensity

        static func from(policy: SyncPolicyStore) -> RunConfiguration {
            let clampedMonths = SyncPolicyStore.clampCoverageMonths(
                policy.coverageScanMonths,
                max: policy.effectiveMaximumCoverageMonths
            )
            return RunConfiguration(
                rangeMonths: clampedMonths,
                intensity: policy.coverageScanIntensity
            )
        }
    }
    
    static func makeThrottleDecision(
        snapshot: RuntimeSnapshot,
        now: Date,
        state: inout ThrottleState,
        intensity: CoverageScanIntensity
    ) -> ThrottleDecision {
        #if os(iOS) || os(watchOS)
        let hardThermal = snapshot.thermalState == .serious || snapshot.thermalState == .critical
        let hardMemory = snapshot.memoryUsedBytes >= memoryHardPressureBytes
        let highMemory = snapshot.memoryUsedBytes >= memoryHighPressureBytes
        let warningMemory = snapshot.memoryUsedBytes >= memorySoftWarningBytes
        
        if hardThermal || hardMemory {
            state.lastReason = hardThermal ? .thermal : .memory
            state.recoveryPagesRemaining = max(state.recoveryPagesRemaining, recoveryPagesAfterHardPause)
            
            let allowHardPause: Bool
            if let lastPause = state.lastHardPauseAt {
                allowHardPause = now.timeIntervalSince(lastPause) >= hardPauseCooldownSeconds
            } else {
                allowHardPause = true
            }
            
            if allowHardPause {
                state.lastHardPauseAt = now
                return adjustedDecision(
                    ThrottleDecision(
                    batchSize: 30,
                    pauseSeconds: hardPauseSeconds,
                    reason: state.lastReason,
                    userFacingStatus: "Optimizing for device memory and temperature..."
                    ),
                    intensity: intensity
                )
            }
            return adjustedDecision(
                ThrottleDecision(
                batchSize: 50,
                pauseSeconds: 0,
                reason: state.lastReason,
                userFacingStatus: "Reducing scan speed to keep the app responsive..."
                ),
                intensity: intensity
            )
        }
        
        if snapshot.isLowPowerModeEnabled {
            state.lastReason = .lowPower
            return adjustedDecision(
                ThrottleDecision(
                batchSize: 80,
                pauseSeconds: 0,
                reason: .lowPower,
                userFacingStatus: "Low Power Mode is on, scanning gently..."
                ),
                intensity: intensity
            )
        }
        
        if highMemory {
            state.lastReason = .memory
            return adjustedDecision(
                ThrottleDecision(
                batchSize: 70,
                pauseSeconds: 0,
                reason: .memory,
                userFacingStatus: "Optimizing for device memory..."
                ),
                intensity: intensity
            )
        }
        
        if warningMemory {
            state.lastReason = .memory
            return adjustedDecision(
                ThrottleDecision(
                batchSize: 120,
                pauseSeconds: 0,
                reason: .memory,
                userFacingStatus: "Reducing scan speed to keep the app responsive..."
                ),
                intensity: intensity
            )
        }
        
        if state.recoveryPagesRemaining > 0 {
            state.recoveryPagesRemaining -= 1
            state.lastReason = .recovery
            return adjustedDecision(
                ThrottleDecision(
                batchSize: 150,
                pauseSeconds: 0,
                reason: .recovery,
                userFacingStatus: "Resuming normal speed..."
                ),
                intensity: intensity
            )
        }
        
        state.lastReason = nil
        switch snapshot.thermalState {
        case .fair:
            return adjustedDecision(
                ThrottleDecision(batchSize: 250, pauseSeconds: 0, reason: .thermal, userFacingStatus: nil),
                intensity: intensity
            )
        case .nominal:
            return adjustedDecision(
                ThrottleDecision(batchSize: pageSize, pauseSeconds: 0, reason: nil, userFacingStatus: nil),
                intensity: intensity
            )
        case .serious, .critical:
            return adjustedDecision(
                ThrottleDecision(
                    batchSize: 75,
                    pauseSeconds: 0,
                    reason: .thermal,
                    userFacingStatus: "Reducing scan speed to keep the app responsive..."
                ),
                intensity: intensity
            )
        @unknown default:
            return adjustedDecision(
                ThrottleDecision(batchSize: 250, pauseSeconds: 0, reason: .thermal, userFacingStatus: nil),
                intensity: intensity
            )
        }
        #else
        return adjustedDecision(
            ThrottleDecision(batchSize: pageSize, pauseSeconds: 0, reason: nil, userFacingStatus: nil),
            intensity: intensity
        )
        #endif
    }

    private static func adjustedDecision(
        _ decision: ThrottleDecision,
        intensity: CoverageScanIntensity
    ) -> ThrottleDecision {
        switch intensity {
        case .balanced:
            return decision
        case .batterySaver:
            let reduced = max(50, Int(Double(decision.batchSize) * 0.75))
            return ThrottleDecision(
                batchSize: reduced,
                pauseSeconds: decision.pauseSeconds,
                reason: decision.reason,
                userFacingStatus: decision.userFacingStatus
            )
        case .faster:
            guard decision.reason == nil, decision.pauseSeconds == 0 else {
                return decision
            }
            let increased = min(pageSize, Int(Double(decision.batchSize) * 1.3))
            return ThrottleDecision(
                batchSize: increased,
                pauseSeconds: 0,
                reason: nil,
                userFacingStatus: decision.userFacingStatus
            )
        }
    }
    
    static func normalizeResumeState(
        _ state: YearScanResumeState?,
        accountsCount: Int,
        totalMonths: Int
    ) -> YearScanResumeState? {
        guard var state else { return nil }
        if accountsCount <= 0 || totalMonths <= 0 {
            return nil
        }
        state.accountIndex = min(max(state.accountIndex, 0), max(accountsCount - 1, 0))
        state.monthIndex = min(max(state.monthIndex, 0), totalMonths)
        if state.phase == .scanning {
            if (state.beforeDate == nil) != (state.beforePk == nil) {
                state.beforeDate = nil
                state.beforePk = nil
            }
        }
        state.totalMonths = totalMonths
        return state
    }
    
    private static func getMemoryUsage() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size)/4
        
        let kerr: kern_return_t = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        
        return kerr == KERN_SUCCESS ? info.resident_size : 0
    }
    
    private static func captureRuntimeSnapshot() -> RuntimeSnapshot {
        #if os(iOS) || os(watchOS)
        return RuntimeSnapshot(
            thermalState: ProcessInfo.processInfo.thermalState,
            isLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            memoryUsedBytes: getMemoryUsage()
        )
        #else
        return RuntimeSnapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: false,
            memoryUsedBytes: getMemoryUsage()
        )
        #endif
    }
    
    
    
    
    
    private static func memoryMB(_ bytes: UInt64) -> UInt64 {
        bytes / 1_000_000
    }
    
    private static func thermalLabel(_ thermal: ProcessInfo.ThermalState) -> String {
        switch thermal {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    private static func normalizedThreadKey(threadId: String?, providerMessageId: String) -> String {
        let normalizedThreadId = threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedThreadId, !normalizedThreadId.isEmpty {
            return normalizedThreadId
        }
        return providerMessageId
    }

    static func run(
        environment: AppEnvironment,
        resumeState: YearScanResumeState? = nil,
        configuration: RunConfiguration? = nil,
        statusUpdate: ((String) -> Void)? = nil,
        checkpointUpdate: ((YearScanResumeState) -> Void)? = nil,
        partialUpdate: ((YearScanPartialUpdate) -> Void)? = nil
    ) async throws -> YearScanRunResult {
        let runStartedAt = Date()
        let scanSignpostID = signposter.makeSignpostID()
        let scanState = signposter.beginInterval("FullScan", id: scanSignpostID)
        var peakMemoryBytes = captureRuntimeSnapshot().memoryUsedBytes
        let accounts = try await environment.mailboxAccountRepository.fetchAll()
        var collected: [YearScanItem] = []
        var scannedMessageCount = resumeState?.scannedMessageCount ?? 0
        let activeConfig = configuration ?? RunConfiguration.from(policy: environment.syncPolicyStore)
        let clampedRangeMonths = SyncPolicyStore.clampCoverageMonths(
            activeConfig.rangeMonths,
            max: environment.syncPolicyStore.effectiveMaximumCoverageMonths
        )
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .month, value: -clampedRangeMonths, to: endDate) ?? endDate
        let monthRanges = buildMonthRanges(startDate: startDate, endDate: endDate)
        let totalMonths = monthRanges.count
        let normalizedResumeState = normalizeResumeState(
            resumeState,
            accountsCount: accounts.count,
            totalMonths: totalMonths
        )
        var currentResumeState = normalizedResumeState
        var throttleState = ThrottleState()
        var monthSummaries = normalizedResumeState?.monthSummaries ?? []
        var providerMonthLabelByMessageId: [String: String] = [:]
        var accumulatedClassifiedByThread: [String: YearScanItem] = [:]
        var accumulatedClassifiedMessageIds: Set<String> = Set()

        Logger.info("YearScan: start (\(accounts.count) accounts)")
        let accountStart = min(max(normalizedResumeState?.accountIndex ?? 0, 0), max(accounts.count - 1, 0))
        for accountIndex in accountStart..<accounts.count {
            let account = accounts[accountIndex]
            Logger.info("YearScan: backfill start account=\(account.emailAddress)")
            var backfillSavedTotal = 0
            let excludedIDs = try await environment.messageStateManager.getExcludedMessageIDs()
            Logger.info("YearScan: account=\(account.emailAddress) excluding \(excludedIDs.count) locally-actioned messages")
            let monthStart = accountIndex == accountStart ? min(max(normalizedResumeState?.monthIndex ?? 0, 0), totalMonths) : 0
            for index in monthStart..<totalMonths {
                let range = monthRanges[index]
                try Task.checkCancellation()
                let monthIndex = index + 1
                let activeMonthLabel = monthLabel(for: range.start)
                let status = "Backfilling: \(activeMonthLabel) (\(monthIndex)/\(totalMonths))"
                statusUpdate?(status)
                let existingSummary = monthSummaries.first(where: { $0.monthLabel == activeMonthLabel })
                monthSummaries = upsertMonthSummary(
                    in: monthSummaries,
                    label: activeMonthLabel,
                    monthIndex: index,
                    messagesScanned: existingSummary?.messagesScanned ?? 0,
                    promotedCount: existingSummary?.promotedCount ?? 0,
                    expectedCount: existingSummary?.expectedCount ?? 0,
                    droppedCount: existingSummary?.droppedCount ?? 0,
                    isInProgress: true,
                    completedAt: nil
                )
                currentResumeState = YearScanResumeState(
                    accountIndex: accountIndex,
                    monthIndex: index,
                    totalMonths: totalMonths,
                    phase: .backfill,
                    beforeDate: nil,
                    beforePk: nil,
                    scannedMessageCount: scannedMessageCount,
                    lastStatusMessage: status,
                    consecutiveQuotaHits: 0,
                    configuredRangeMonths: clampedRangeMonths,
                    configuredIntensity: activeConfig.intensity.rawValue,
                    currentMonthLabel: activeMonthLabel,
                    currentPage: nil,
                    monthSummaries: monthSummaries
                )
                if let state = currentResumeState {
                    checkpointUpdate?(state)
                }
                let backfillReport: SyncReport
                let backfillSignpostID = signposter.makeSignpostID()
                let backfillState = signposter.beginInterval("MonthBackfill", id: backfillSignpostID, "\(activeMonthLabel)")
                do {
                    backfillReport = try await environment.gmailSyncCoordinator.backfill(
                        mailboxAccountId: account.id,
                        startDate: range.start,
                        endDate: range.end,
                        daysBackForExtraction: 0
                    )
                    signposter.endInterval("MonthBackfill", backfillState)
                } catch {
                    signposter.endInterval("MonthBackfill", backfillState)
                    if isQuotaRelatedError(error) {
                        let resumable = currentResumeState ?? YearScanResumeState(
                            accountIndex: accountIndex,
                            monthIndex: max(index - 1, 0),
                            totalMonths: totalMonths,
                            phase: .backfill,
                            beforeDate: nil,
                            beforePk: nil,
                            scannedMessageCount: scannedMessageCount,
                            lastStatusMessage: status,
                            consecutiveQuotaHits: (normalizedResumeState?.consecutiveQuotaHits ?? 0) + 1,
                            configuredRangeMonths: clampedRangeMonths,
                            configuredIntensity: activeConfig.intensity.rawValue
                        )
                        throw YearScanQuotaStoppedError(
                            lastCompletedMonthIndex: index - 1,
                            totalMonths: totalMonths,
                            resumeState: resumable
                        )
                    }
                    throw error
                }
                backfillSavedTotal += backfillReport.messagesSavedCount
                let monthClassification: (promoted: Int, expected: Int, dropped: Int)
                let classifySignpostID = signposter.makeSignpostID()
                let classifyState = signposter.beginInterval("MonthClassify", id: classifySignpostID, "\(activeMonthLabel)")
                do {
                    statusUpdate?("Classifying: \(activeMonthLabel)...")
                    let classResult = try await classifyMonthSlice(
                        environment: environment,
                        mailboxAccountId: account.id,
                        startDate: range.start,
                        endDate: range.end,
                        excludedProviderMessageIds: excludedIDs
                    )
                    monthClassification = (classResult.promoted, classResult.expected, classResult.dropped)
                    for (key, item) in classResult.classifiedItems {
                        if let existing = accumulatedClassifiedByThread[key] {
                            if item.isHigherPriority(than: existing) {
                                accumulatedClassifiedByThread[key] = item
                            }
                        } else {
                            accumulatedClassifiedByThread[key] = item
                        }
                    }
                    accumulatedClassifiedMessageIds.formUnion(
                        classResult.classifiedItems.values.map(\.providerMessageId)
                    )
                    for item in classResult.classifiedItems.values {
                        providerMonthLabelByMessageId[item.providerMessageId] = activeMonthLabel
                    }
                    await Task.yield()
                    signposter.endInterval("MonthClassify", classifyState)
                } catch {
                    signposter.endInterval("MonthClassify", classifyState)
                    Logger.info(
                        "YearScan: classify slice failed month=\(monthIndex)/\(totalMonths) error=\(error.localizedDescription)"
                    )
                    monthClassification = (0, 0, 0)
                }
                let completedSummary = monthSummaries.first(where: { $0.monthLabel == activeMonthLabel })
                monthSummaries = upsertMonthSummary(
                    in: monthSummaries,
                    label: activeMonthLabel,
                    monthIndex: index,
                    messagesScanned: (completedSummary?.messagesScanned ?? 0) + backfillReport.messagesSavedCount,
                    promotedCount: monthClassification.promoted,
                    expectedCount: monthClassification.expected,
                    droppedCount: monthClassification.dropped,
                    isInProgress: false,
                    completedAt: Date()
                )
                currentResumeState = YearScanResumeState(
                    accountIndex: accountIndex,
                    monthIndex: min(index + 1, totalMonths),
                    totalMonths: totalMonths,
                    phase: .backfill,
                    beforeDate: nil,
                    beforePk: nil,
                    scannedMessageCount: scannedMessageCount,
                    lastStatusMessage: "Backfill completed: \(activeMonthLabel)",
                    consecutiveQuotaHits: 0,
                    configuredRangeMonths: clampedRangeMonths,
                    configuredIntensity: activeConfig.intensity.rawValue,
                    currentMonthLabel: activeMonthLabel,
                    currentPage: nil,
                    monthSummaries: monthSummaries
                )
                if let state = currentResumeState {
                    checkpointUpdate?(state)
                }
                Logger.info(
                    "YearScan: backfill slice account=\(account.emailAddress) month=\(monthIndex)/\(totalMonths) saved=\(backfillReport.messagesSavedCount) promoted=\(monthClassification.promoted) expected=\(monthClassification.expected) dropped=\(monthClassification.dropped)"
                )
            }
            Logger.info(
                "YearScan: backfill done account=\(account.emailAddress) saved=\(backfillSavedTotal)"
            )
            
            // Checkpoint WAL after backfill to prevent unbounded growth
            try? await environment.database.checkpoint()

            collected.append(contentsOf: accumulatedClassifiedByThread.values)
            if let state = currentResumeState {
                partialUpdate?(
                    YearScanPartialUpdate(
                        items: sortItems(collected),
                        scannedMessageCount: scannedMessageCount,
                        resumeState: state,
                        statusMessage: state.lastStatusMessage ?? "Finalizing results..."
                    )
                )
            }
        }

        let sorted = sortItems(collected)
        let elapsedSeconds = Date().timeIntervalSince(runStartedAt)
        let telemetry = YearScanRunTelemetry(
            stopReason: "completed",
            elapsedSeconds: elapsedSeconds,
            peakMemoryMB: memoryMB(peakMemoryBytes),
            pagesScanned: totalMonths,
            effectiveBatchSize: 0,
            minBatchSize: 0,
            maxBatchSize: 0
        )
        AppLog.info(
            "YearScan.run.completed",
            fields: [
                "stopReason": telemetry.stopReason,
                "elapsedSeconds": String(format: "%.2f", telemetry.elapsedSeconds),
                "peakMemoryMB": telemetry.peakMemoryMB,
                "pagesScanned": telemetry.pagesScanned,
                "effectiveBatchSize": telemetry.effectiveBatchSize,
                "minBatchSize": telemetry.minBatchSize,
                "maxBatchSize": telemetry.maxBatchSize
            ]
        )
        Logger.info("YearScan: done scanned=\(scannedMessageCount) results=\(sorted.count)")
        PerfMetrics.logScanRun(PerfMetrics.ScanRunSummary(
            elapsedSeconds: elapsedSeconds,
            peakMemoryMB: memoryMB(peakMemoryBytes),
            pagesScanned: totalMonths,
            monthsBackfilled: totalMonths,
            messagesClassified: scannedMessageCount,
            throttleEvents: throttleState.recoveryPagesRemaining > 0 ? 1 : 0,
            averageBatchSize: 0
        ))
        signposter.endInterval("FullScan", scanState)
        return YearScanRunResult(
            items: sorted,
            scannedMessageCount: scannedMessageCount,
            resumeState: currentResumeState,
            telemetry: telemetry
        )
    }

    private static func sortItems(_ items: [YearScanItem]) -> [YearScanItem] {
        items.sorted { lhs, rhs in
            if lhs.promotionDecision != rhs.promotionDecision {
                return lhs.isHigherPriority(than: rhs)
            }
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.detectedAt > rhs.detectedAt
        }
    }

    private static func buildMonthRanges(startDate: Date, endDate: Date) -> [(start: Date, end: Date)] {
        let calendar = Calendar.current
        var ranges: [(start: Date, end: Date)] = []
        var cursor = startDate

        while cursor < endDate {
            let next = calendar.date(byAdding: .month, value: 1, to: cursor) ?? endDate
            let sliceEnd = min(next, endDate)
            ranges.append((start: cursor, end: sliceEnd))
            cursor = sliceEnd
        }

        return ranges
    }

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()

    private static func monthLabel(for date: Date) -> String {
        monthFormatter.string(from: date)
    }

    private static func upsertMonthSummary(
        in summaries: [YearScanMonthSummary],
        label: String,
        monthIndex: Int,
        messagesScanned: Int,
        promotedCount: Int,
        expectedCount: Int,
        droppedCount: Int,
        isInProgress: Bool,
        completedAt: Date?
    ) -> [YearScanMonthSummary] {
        var copy = summaries
        if let existingIndex = copy.firstIndex(where: { $0.monthLabel == label }) {
            copy[existingIndex] = YearScanMonthSummary(
                monthLabel: label,
                monthIndex: monthIndex,
                messagesScanned: messagesScanned,
                promotedCount: promotedCount,
                expectedCount: expectedCount,
                droppedCount: droppedCount,
                isInProgress: isInProgress,
                completedAt: completedAt
            )
        } else {
            copy.append(
                YearScanMonthSummary(
                    monthLabel: label,
                    monthIndex: monthIndex,
                    messagesScanned: messagesScanned,
                    promotedCount: promotedCount,
                    expectedCount: expectedCount,
                    droppedCount: droppedCount,
                    isInProgress: isInProgress,
                    completedAt: completedAt
                )
            )
        }
        return copy.sorted { lhs, rhs in
            lhs.monthIndex < rhs.monthIndex
        }
    }

    private static func applyCounts(
        _ counts: [String: (promoted: Int, expected: Int, dropped: Int)],
        to existingSummaries: [YearScanMonthSummary]
    ) -> [YearScanMonthSummary] {
        var merged = existingSummaries
        for (label, bucket) in counts {
            let existing = merged.first(where: { $0.monthLabel == label })
            let monthIndex = existing?.monthIndex ?? Int.max
            merged = upsertMonthSummary(
                in: merged,
                label: label,
                monthIndex: monthIndex,
                messagesScanned: existing?.messagesScanned ?? 0,
                promotedCount: bucket.promoted,
                expectedCount: bucket.expected,
                droppedCount: bucket.dropped,
                isInProgress: existing?.isInProgress ?? false,
                completedAt: existing?.completedAt
            )
        }
        return merged
    }

    private static func classifyMonthSlice(
        environment: AppEnvironment,
        mailboxAccountId: String,
        startDate: Date,
        endDate: Date,
        excludedProviderMessageIds: Set<String>
    ) async throws -> (promoted: Int, expected: Int, dropped: Int, classifiedItems: [String: YearScanItem]) {
        var beforeDate: Date?
        var beforePk: Int64?
        var bestByThread: [String: YearScanItem] = [:]

        while true {
            try Task.checkCancellation()
            await Task.yield()
            let messages = try await environment.messageRepository.fetchInDateRangePage(
                mailboxAccountId: mailboxAccountId,
                startDate: startDate,
                endDate: endDate,
                beforeDate: beforeDate,
                beforePk: beforePk,
                limit: pageSize
            )

            guard !messages.isEmpty else { break }
            let filtered = messages.filter { !excludedProviderMessageIds.contains($0.providerMessageId) }
            if !filtered.isEmpty {
                let scanned = try await environment.obligationExtractor.scanYear(
                    messages: filtered,
                    mailboxAccountId: mailboxAccountId
                )
                for item in scanned {
                    let key = normalizedThreadKey(threadId: item.threadId, providerMessageId: item.providerMessageId)
                    if let existing = bestByThread[key] {
                        if item.isHigherPriority(than: existing) {
                            bestByThread[key] = item
                        }
                    } else {
                        bestByThread[key] = item
                    }
                }
            }

            guard let last = messages.last, let lastPk = last.pk else { break }
            beforeDate = last.internalDate
            beforePk = lastPk

            if messages.count < pageSize { break }
        }

        var promoted = 0
        var expected = 0
        var dropped = 0
        for item in bestByThread.values {
            switch item.promotionDecision {
            case .promoted:
                promoted += 1
            case .expectedEvent:
                expected += 1
            case .dropped:
                dropped += 1
            }
        }
        return (promoted, expected, dropped, classifiedItems: bestByThread)
    }

    private static func isQuotaRelatedError(_ error: Error) -> Bool {
        if case GmailClientError.apiError(let code, _) = error {
            return code == 429 || code == 403
        }
        return false
    }

    // MARK: - Lifecycle helpers

    static func persistInProgress(
        environment: AppEnvironment,
        scannedMessageCount: Int,
        statusMessage: String?,
        resumeState: YearScanResumeState?,
        configuration: RunConfiguration
    ) async {
        try? await environment.yearScanRepository.markInProgress(
            scannedMessageCount: scannedMessageCount,
            coverageSummary: coverageSummary,
            statusMessage: statusMessage,
            resumeState: resumeState,
            scanRangeMonths: configuration.rangeMonths,
            scanIntensity: configuration.intensity.rawValue
        )
    }

    static func persistPaused(
        environment: AppEnvironment,
        scannedMessageCount: Int,
        statusMessage: String?,
        resumeState: YearScanResumeState?,
        configuration: RunConfiguration
    ) async {
        try? await environment.yearScanRepository.markPaused(
            scannedMessageCount: scannedMessageCount,
            coverageSummary: coverageSummary,
            statusMessage: statusMessage,
            resumeState: resumeState,
            scanRangeMonths: configuration.rangeMonths,
            scanIntensity: configuration.intensity.rawValue
        )
    }

    static func clearResumeState(environment: AppEnvironment) async {
        try? await environment.yearScanRepository.clearResumeState()
    }

    static func bridgePromotedFindingsToObligations(
        environment: AppEnvironment,
        items: [YearScanItem]
    ) async {
        let promoted = items.filter { $0.promotionDecision == .promoted }
        guard !promoted.isEmpty else { return }

        let excludedMessageIDs = (try? await environment.messageStateManager.getExcludedMessageIDsCached(maxAge: 0)) ?? []
        let grouped = Dictionary(grouping: promoted, by: { $0.mailboxAccountId })
        var records: [ObligationRecord] = []

        for (mailboxAccountId, accountItems) in grouped {
            let providerIDs = Set(
                accountItems
                    .map(\.providerMessageId)
                    .filter { !excludedMessageIDs.contains($0) }
            )
            guard !providerIDs.isEmpty else { continue }

            let blocked = (try? await environment.suppressionRepository.fetchAllBlocked(
                mailboxAccountId: mailboxAccountId
            )) ?? BlockedSendersAndDomains(senders: [], domains: [])

            let messages = (try? await environment.messageRepository.fetchByProviderMessageIds(
                mailboxAccountId: mailboxAccountId,
                providerMessageIds: providerIDs
            )) ?? []

            for message in messages {
                guard let messagePk = message.pk else { continue }
                if blocked.isBlocked(sender: message.fromEmail, domain: message.fromDomain) { continue }

                guard let matchedItem = accountItems.first(where: { $0.providerMessageId == message.providerMessageId }),
                      matchedItem.promotionDecision == .promoted else {
                    continue
                }
                let assessment = try? await environment.obligationExtractor.assess(
                    message: message,
                    mailboxAccountId: mailboxAccountId
                )
                guard let assessment else { continue }
                var record = environment.obligationExtractor.makeObligation(
                    from: assessment,
                    message: message,
                    mailboxAccountId: mailboxAccountId,
                    messagePk: messagePk,
                    email: nil
                )
                record.confidence = matchedItem.confidence
                record.deadlineAt = matchedItem.dueDate
                if record.evidenceQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    record.evidenceQuote = matchedItem.snippet
                }
                records.append(record)
            }
        }

        guard !records.isEmpty else { return }
        try? await environment.obligationRepository.save(records)
    }
}
