import Foundation

struct YearScanRunResult {
    let items: [YearScanItem]
    let scannedMessageCount: Int
    let resumeState: YearScanResumeState?
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

enum YearScanCoordinator {
    static func run(
        environment: AppEnvironment,
        resumeState: YearScanResumeState?,
        configuration: YearScanRunner.RunConfiguration? = nil,
        statusUpdate: ((String) -> Void)? = nil,
        checkpointUpdate: ((YearScanResumeState) -> Void)? = nil,
        partialUpdate: ((YearScanPartialUpdate) -> Void)? = nil
    ) async throws -> YearScanRunResult {
        try await YearScanRunner.run(
            environment: environment,
            resumeState: resumeState,
            configuration: configuration,
            statusUpdate: statusUpdate,
            checkpointUpdate: checkpointUpdate,
            partialUpdate: partialUpdate
        )
    }

    static func persistInProgress(
        environment: AppEnvironment,
        scannedMessageCount: Int,
        statusMessage: String?,
        resumeState: YearScanResumeState?,
        configuration: YearScanRunner.RunConfiguration
    ) async {
        try? await environment.yearScanRepository.markInProgress(
            scannedMessageCount: scannedMessageCount,
            coverageSummary: YearScanRunner.coverageSummary,
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
        configuration: YearScanRunner.RunConfiguration
    ) async {
        try? await environment.yearScanRepository.markPaused(
            scannedMessageCount: scannedMessageCount,
            coverageSummary: YearScanRunner.coverageSummary,
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

            let messages = (try? await environment.messageRepository.fetchByProviderMessageIds(
                mailboxAccountId: mailboxAccountId,
                providerMessageIds: providerIDs
            )) ?? []

            for message in messages {
                guard let messagePk = message.pk else { continue }
                let isSuppressed = (try? await environment.suppressionRepository.isBlocked(
                    mailboxAccountId: mailboxAccountId,
                    sender: message.fromEmail,
                    domain: message.fromDomain
                )) ?? false
                if isSuppressed { continue }

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
                    messagePk: messagePk
                )
                // Preserve year-scan calibrated values instead of re-assessment defaults.
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

enum YearScanRunner {
    static let coverageSummary = "Inbox, excluding promotions & social"
    private static let pageSize = 500
    private static let checkpointEveryPages = 10
    private static let checkpointEverySeconds: TimeInterval = 20
    private static let partialUpdateEveryPages = 3
    private static let partialUpdateEverySeconds: TimeInterval = 3
    private static let workingSetSoftLimit = 1000
    private static let workingSetHardCap = 700
    
    private static let memorySoftWarningBytes: UInt64 = 450_000_000
    private static let memoryHighPressureBytes: UInt64 = 550_000_000
    private static let memoryHardPressureBytes: UInt64 = 700_000_000
    private static let hardPauseSeconds: UInt64 = 5
    private static let hardPauseCooldownSeconds: TimeInterval = 20
    private static let recoveryPagesAfterHardPause = 6
    
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
            RunConfiguration(
                rangeMonths: SyncPolicyStore.clampCoverageMonths(policy.coverageScanMonths),
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
                    batchSize: 50,
                    pauseSeconds: hardPauseSeconds,
                    reason: state.lastReason,
                    userFacingStatus: "Optimizing for device memory and temperature..."
                    ),
                    intensity: intensity
                )
            }
            return adjustedDecision(
                ThrottleDecision(
                batchSize: 75,
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
                batchSize: 120,
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
                batchSize: 100,
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
                batchSize: 150,
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
                batchSize: 200,
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
    
    private static func shouldCheckpoint(page: Int, lastCheckpointAt: Date, now: Date) -> Bool {
        if page % checkpointEveryPages == 0 { return true }
        return now.timeIntervalSince(lastCheckpointAt) >= checkpointEverySeconds
    }

    private static func shouldEmitPartial(
        page: Int,
        lastPartialAt: Date,
        lastPartialPage: Int,
        now: Date
    ) -> Bool {
        if page - lastPartialPage >= partialUpdateEveryPages {
            return true
        }
        return now.timeIntervalSince(lastPartialAt) >= partialUpdateEverySeconds
    }
    
    private static func trimWorkingSet(_ bestByThread: [String: YearScanItem]) -> [String: YearScanItem] {
        guard bestByThread.count > workingSetHardCap else { return bestByThread }
        let kept = bestByThread.values
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                if $0.detectedAt != $1.detectedAt {
                    return $0.detectedAt > $1.detectedAt
                }
                return $0.id < $1.id
            }
            .prefix(workingSetHardCap)
        return Dictionary(uniqueKeysWithValues: kept.map { (($0.threadId ?? $0.providerMessageId), $0) })
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

    static func run(
        environment: AppEnvironment,
        resumeState: YearScanResumeState? = nil,
        configuration: RunConfiguration? = nil,
        statusUpdate: ((String) -> Void)? = nil,
        checkpointUpdate: ((YearScanResumeState) -> Void)? = nil,
        partialUpdate: ((YearScanPartialUpdate) -> Void)? = nil
    ) async throws -> YearScanRunResult {
        let accounts = try await environment.mailboxAccountRepository.fetchAll()
        var collected: [YearScanItem] = []
        var scannedMessageCount = resumeState?.scannedMessageCount ?? 0
        let activeConfig = configuration ?? RunConfiguration.from(policy: environment.syncPolicyStore)
        let clampedRangeMonths = SyncPolicyStore.clampCoverageMonths(activeConfig.rangeMonths)
        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .month, value: -clampedRangeMonths, to: endDate) ?? endDate
        let monthRanges = buildMonthRanges(startDate: startDate, endDate: endDate)
        let totalMonths = monthRanges.count
        let scanDays = max(1, Calendar.current.dateComponents([.day], from: startDate, to: endDate).day ?? 365)
        let normalizedResumeState = normalizeResumeState(
            resumeState,
            accountsCount: accounts.count,
            totalMonths: totalMonths
        )
        var currentResumeState = normalizedResumeState
        var throttleState = ThrottleState()
        var monthSummaries = normalizedResumeState?.monthSummaries ?? []
        var providerMonthLabelByMessageId: [String: String] = [:]

        Logger.info("YearScan: start (\(accounts.count) accounts)")
        let accountStart = min(max(normalizedResumeState?.accountIndex ?? 0, 0), max(accounts.count - 1, 0))
        for accountIndex in accountStart..<accounts.count {
            let account = accounts[accountIndex]
            Logger.info("YearScan: backfill start account=\(account.emailAddress)")
            var backfillSavedTotal = 0
            let monthStart = accountIndex == accountStart ? min(max(normalizedResumeState?.monthIndex ?? 0, 0), totalMonths) : 0
            for index in monthStart..<totalMonths {
                let range = monthRanges[index]
                try Task.checkCancellation()
                let monthIndex = index + 1
                let activeMonthLabel = monthLabel(for: range.start)
                let status = "Backfilling: \(activeMonthLabel) (\(monthIndex)/\(totalMonths))"
                statusUpdate?(status)
                monthSummaries = upsertMonthSummary(
                    in: monthSummaries,
                    label: activeMonthLabel,
                    monthIndex: index,
                    messagesScanned: 0,
                    promotedCount: 0,
                    expectedCount: 0,
                    droppedCount: 0,
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
                do {
                    backfillReport = try await environment.gmailSyncCoordinator.backfill(
                        mailboxAccountId: account.id,
                        startDate: range.start,
                        endDate: range.end,
                        daysBackForExtraction: 0
                    )
                } catch {
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
                monthSummaries = upsertMonthSummary(
                    in: monthSummaries,
                    label: activeMonthLabel,
                    monthIndex: index,
                    messagesScanned: backfillReport.messagesSavedCount,
                    promotedCount: 0,
                    expectedCount: 0,
                    droppedCount: 0,
                    isInProgress: false,
                    completedAt: Date()
                )
                Logger.info(
                    "YearScan: backfill slice account=\(account.emailAddress) month=\(monthIndex)/\(totalMonths) saved=\(backfillReport.messagesSavedCount)"
                )
            }
            Logger.info(
                "YearScan: backfill done account=\(account.emailAddress) saved=\(backfillSavedTotal)"
            )
            
            // Checkpoint WAL after backfill to prevent unbounded growth
            try? await environment.database.checkpoint()

            var beforeDate: Date?
            var beforePk: Int64?
            var page = 0
            var bestByThread: [String: YearScanItem] = [:]
            var lastCheckpointAt = Date.distantPast
            var lastPartialUpdateAt = Date.distantPast
            var lastPartialUpdatePage = 0
            
            // Load excluded message IDs once for performance
            let excludedIDs = try await environment.messageStateManager.getExcludedMessageIDs()
            Logger.info("YearScan: account=\(account.emailAddress) excluding \(excludedIDs.count) locally-actioned messages")

            while true {
                try Task.checkCancellation()
                let snapshot = captureRuntimeSnapshot()
                let now = Date()
                let decision = makeThrottleDecision(
                    snapshot: snapshot,
                    now: now,
                    state: &throttleState,
                    intensity: activeConfig.intensity
                )
                if let reason = decision.reason {
                    Logger.info(
                        "YearScan: throttle reason=\(reason.rawValue) thermal=\(thermalLabel(snapshot.thermalState)) lowPower=\(snapshot.isLowPowerModeEnabled) memoryMB=\(memoryMB(snapshot.memoryUsedBytes)) batch=\(decision.batchSize) pause=\(decision.pauseSeconds)s"
                    )
                } else if snapshot.memoryUsedBytes >= memorySoftWarningBytes {
                    Logger.info(
                        "YearScan: memory warning thermal=\(thermalLabel(snapshot.thermalState)) memoryMB=\(memoryMB(snapshot.memoryUsedBytes))"
                    )
                }
                if decision.shouldPause {
                    statusUpdate?("Scanning paused briefly. \(decision.userFacingStatus ?? "Optimizing for device constraints...")")
                    Logger.info("YearScan: pausing for \(decision.pauseSeconds)s due to device constraints")
                    try? await Task.sleep(nanoseconds: decision.pauseSeconds * 1_000_000_000)
                }
                if bestByThread.count > workingSetSoftLimit || snapshot.memoryUsedBytes >= memoryHighPressureBytes {
                    let before = bestByThread.count
                    bestByThread = trimWorkingSet(bestByThread)
                    let after = bestByThread.count
                    if after < before {
                        Logger.info("YearScan: trimmed working set from \(before) to \(after) items")
                    }
                }

                let status = "Scanning inbox..."
                statusUpdate?(status)
                
                let currentPageSize = max(50, decision.batchSize)
                
                let messages = try await environment.messageRepository.fetchRecentPage(
                    mailboxAccountId: account.id,
                    daysBack: scanDays,
                    beforeDate: beforeDate,
                    beforePk: beforePk,
                    limit: currentPageSize
                )

                guard !messages.isEmpty else {
                    Logger.info("YearScan: account=\(account.emailAddress) page=\(page) done")
                    break
                }
                
                // Filter out messages that have been deleted, dismissed, or archived locally
                // UserActionRecord.messageID corresponds to MessageRecord.providerMessageId
                let filteredMessages = messages.filter { !excludedIDs.contains($0.providerMessageId) }
                for message in filteredMessages {
                    providerMonthLabelByMessageId[message.providerMessageId] = monthLabel(for: message.internalDate)
                }

                page += 1
                scannedMessageCount += messages.count  // Track total fetched for cursor management
                let scanningStatusBase = "Scanning inbox... \(scannedMessageCount) messages"
                let scanningStatus: String
                if let note = decision.userFacingStatus {
                    scanningStatus = "\(scanningStatusBase) • \(note)"
                } else {
                    scanningStatus = scanningStatusBase
                }
                statusUpdate?(scanningStatus)

                if !filteredMessages.isEmpty {
                    if let oldest = filteredMessages.last?.internalDate {
                        Logger.info("YearScan: account=\(account.emailAddress) page=\(page) fetched=\(messages.count) filtered=\(filteredMessages.count) oldest=\(oldest)")
                    } else {
                        Logger.info("YearScan: account=\(account.emailAddress) page=\(page) fetched=\(messages.count) filtered=\(filteredMessages.count)")
                    }

                    let memoryBeforeExtraction = captureRuntimeSnapshot().memoryUsedBytes
                    let scanned = try await environment.obligationExtractor.scanYear(
                        messages: filteredMessages,
                        mailboxAccountId: account.id
                    )
                    let memoryAfterExtraction = captureRuntimeSnapshot().memoryUsedBytes
                    Logger.info(
                        "YearScan: page=\(page) memoryMB extraction_before=\(memoryMB(memoryBeforeExtraction)) extraction_after=\(memoryMB(memoryAfterExtraction))"
                    )

                    autoreleasepool {
                        for item in scanned {
                            let key = item.threadId ?? item.providerMessageId
                            if let existing = bestByThread[key] {
                                if item.isHigherPriority(than: existing) {
                                    bestByThread[key] = item
                                }
                            } else {
                                bestByThread[key] = item
                            }
                        }
                    }
                } else {
                    Logger.info("YearScan: account=\(account.emailAddress) page=\(page) fetched=\(messages.count) all filtered out")
                }

                guard let last = messages.last, let lastPk = last.pk else {
                    Logger.info("YearScan: account=\(account.emailAddress) page=\(page) missing cursor, stopping")
                    break
                }

                // Use unfiltered messages for pagination cursor to avoid skipping data
                beforeDate = last.internalDate
                beforePk = lastPk
                currentResumeState = YearScanResumeState(
                    accountIndex: accountIndex,
                    monthIndex: totalMonths,
                    totalMonths: totalMonths,
                    phase: .scanning,
                    beforeDate: beforeDate,
                    beforePk: beforePk,
                    scannedMessageCount: scannedMessageCount,
                    lastStatusMessage: scanningStatus,
                    consecutiveQuotaHits: 0,
                    lastThrottleReason: decision.reason?.rawValue,
                    lastKnownMemoryBytes: snapshot.memoryUsedBytes,
                    lastKnownThermalState: thermalLabel(snapshot.thermalState),
                    lastKnownBatchSize: currentPageSize,
                    configuredRangeMonths: clampedRangeMonths,
                    configuredIntensity: activeConfig.intensity.rawValue,
                    currentMonthLabel: monthLabel(for: messages.last?.internalDate ?? Date()),
                    currentPage: page,
                    monthSummaries: buildMonthSummaries(
                        from: bestByThread,
                        providerMonthLabels: providerMonthLabelByMessageId,
                        existingSummaries: monthSummaries
                    )
                )
                monthSummaries = currentResumeState?.monthSummaries ?? monthSummaries
                if let state = currentResumeState {
                    checkpointUpdate?(state)
                    if shouldEmitPartial(
                        page: page,
                        lastPartialAt: lastPartialUpdateAt,
                        lastPartialPage: lastPartialUpdatePage,
                        now: now
                    ) {
                        partialUpdate?(
                            YearScanPartialUpdate(
                                items: sortItems(Array(bestByThread.values)),
                                scannedMessageCount: scannedMessageCount,
                                resumeState: state,
                                statusMessage: scanningStatus
                            )
                        )
                        lastPartialUpdateAt = now
                        lastPartialUpdatePage = page
                    }
                }
                
                // Periodic checkpoint to keep sqlite/WAL memory bounded during long scans.
                if shouldCheckpoint(page: page, lastCheckpointAt: lastCheckpointAt, now: now) {
                    try? await environment.database.checkpoint()
                    lastCheckpointAt = now
                }

                if messages.count < currentPageSize {
                    Logger.info("YearScan: account=\(account.emailAddress) page=\(page) reached end of range")
                    break
                }
            }

            collected.append(contentsOf: bestByThread.values)
            if let state = currentResumeState {
                partialUpdate?(
                    YearScanPartialUpdate(
                        items: sortItems(Array(bestByThread.values)),
                        scannedMessageCount: scannedMessageCount,
                        resumeState: state,
                        statusMessage: state.lastStatusMessage ?? "Scanning inbox..."
                    )
                )
            }
        }

        let sorted = sortItems(collected)
        Logger.info("YearScan: done scanned=\(scannedMessageCount) results=\(sorted.count)")
        return YearScanRunResult(items: sorted, scannedMessageCount: scannedMessageCount, resumeState: currentResumeState)
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

    private static func monthLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM yyyy"
        return formatter.string(from: date)
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

    private static func buildMonthSummaries(
        from bestByThread: [String: YearScanItem],
        providerMonthLabels: [String: String],
        existingSummaries: [YearScanMonthSummary]
    ) -> [YearScanMonthSummary] {
        var aggregated: [String: (promoted: Int, expected: Int, dropped: Int)] = [:]
        for item in bestByThread.values {
            let month = providerMonthLabels[item.providerMessageId] ?? "Unknown"
            var bucket = aggregated[month] ?? (0, 0, 0)
            switch item.promotionDecision {
            case .promoted:
                bucket.promoted += 1
            case .expectedEvent:
                bucket.expected += 1
            case .dropped:
                bucket.dropped += 1
            }
            aggregated[month] = bucket
        }

        var merged: [YearScanMonthSummary] = existingSummaries
        for (label, counts) in aggregated {
            let existing = merged.first(where: { $0.monthLabel == label })
            let monthIndex = existing?.monthIndex ?? Int.max
            merged = upsertMonthSummary(
                in: merged,
                label: label,
                monthIndex: monthIndex,
                messagesScanned: existing?.messagesScanned ?? 0,
                promotedCount: counts.promoted,
                expectedCount: counts.expected,
                droppedCount: counts.dropped,
                isInProgress: existing?.isInProgress ?? false,
                completedAt: existing?.completedAt
            )
        }
        return merged
    }

    private static func isQuotaRelatedError(_ error: Error) -> Bool {
        if case GmailClientError.apiError(let code, _) = error {
            return code == 429 || code == 403
        }
        return false
    }
}
