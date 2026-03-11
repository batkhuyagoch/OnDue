import Foundation
import Combine

enum CoverageDisplayError: Equatable {
    case quota
    case auth
    case network
    case generic
}

enum CoverageUIState: Equatable {
    case idle(needsConnection: Bool)
    case running
    case paused
    case completed(hasFindings: Bool)
    case failed
}

enum CoverageStatusPresenter {
    static func displayError(from error: Error?) -> CoverageDisplayError {
        guard let error else { return .generic }
        if error is YearScanQuotaStoppedError {
            return .quota
        }
        let description = (error as NSError).localizedDescription.lowercased()
        if description.contains("auth") || description.contains("sign in") || description.contains("unauthorized") {
            return .auth
        }
        if description.contains("network") || description.contains("offline") || description.contains("timed out") {
            return .network
        }
        return .generic
    }

    static func errorMessage(for kind: CoverageDisplayError) -> String {
        switch kind {
        case .quota:
            return "Gmail API limit reached. Your progress is saved and you can resume shortly."
        case .auth:
            return "Gmail authorization is required. Reconnect your account and try again."
        case .network:
            return "Network issue while checking coverage. Try again when your connection is stable."
        case .generic:
            return "Coverage check failed. Try again."
        }
    }

    static func title(for state: CoverageUIState) -> String {
        switch state {
        case .idle(let needsConnection):
            return needsConnection ? "Connect Gmail to run coverage check" : "You're all clear"
        case .running:
            return "Checking coverage"
        case .paused:
            return "Coverage check paused"
        case .completed(let hasFindings):
            return hasFindings ? "Items may need attention" : "You're all clear"
        case .failed:
            return "Coverage check failed"
        }
    }

    static func progressMessage(from raw: String) -> String {
        let lower = raw.lowercased()

        if lower.contains("optimizing for device memory") {
            return "Optimizing for device memory..."
        }
        if lower.contains("reducing scan speed") {
            return "Reducing scan speed to keep the app responsive..."
        }
        if lower.contains("scanning paused briefly") || lower.contains("device constraints") {
            return "Paused briefly due to device constraints. Resuming automatically."
        }
        if lower.hasPrefix("backfilling:") {
            if let progress = extractMonthProgress(from: raw) {
                return "Scanning month \(progress.current) of \(progress.total)..."
            }
            return "Collecting email history..."
        }
        if let scanned = extractScannedCount(from: raw) {
            return "\(scanned) messages scanned so far."
        }
        if lower.contains("gmailclient.") || lower.contains("listmessageids") || lower.contains("slice |") {
            return "Reviewing email history..."
        }
        return raw
    }

    private static func extractScannedCount(from status: String) -> Int? {
        let pattern = #"Scanning inbox\.\.\. ([0-9]+) messages"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(status.startIndex..<status.endIndex, in: status)
        guard let match = regex.firstMatch(in: status, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: status) else {
            return nil
        }
        return Int(status[range])
    }

    private static func extractMonthProgress(from status: String) -> (current: Int, total: Int)? {
        let pattern = #"\(([0-9]+)\/([0-9]+)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(status.startIndex..<status.endIndex, in: status)
        guard let match = regex.firstMatch(in: status, options: [], range: nsRange),
              match.numberOfRanges > 2,
              let currentRange = Range(match.range(at: 1), in: status),
              let totalRange = Range(match.range(at: 2), in: status),
              let current = Int(status[currentRange]),
              let total = Int(status[totalRange]) else {
            return nil
        }
        return (current, total)
    }
}

@MainActor
final class YearScanViewModel: ObservableObject {
    @Published private(set) var uiState: CoverageUIState = .idle(needsConnection: false)
    @Published private(set) var isLoading = false
    @Published private(set) var results: [YearScanItem] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var lastPaused: Date?
    @Published private(set) var error: Error?
    @Published private(set) var scannedMessageCount: Int = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var isInProgress = false
    @Published private(set) var progressFraction: Double?
    @Published private(set) var expectedEventSignals: [ExpectedEventPatternSignal] = []
    @Published private(set) var droppedReasonCounts: [LongScanPromotionReasonCode: Int] = [:]
    @Published private(set) var monthSummaries: [YearScanMonthSummary] = []

    private(set) var coverageSummary = YearScanRunner.coverageSummary
    private var accountsById: [String: MailboxAccountRecord] = [:]
    private var scanTask: Task<Void, Never>?
    private var latestResumeState: YearScanResumeState?
    private var estimatedScanMessages: Int?
    private var activeRunToken: String?
    private var partialSequence: Int = 0

    var progressHeadline: String {
        if let resume = latestResumeState {
            switch resume.phase {
            case .backfill:
                let monthNumber = min(resume.monthIndex + 1, max(resume.totalMonths, 1))
                return "Collecting email history (\(monthNumber) of \(max(resume.totalMonths, 1)) months)"
            case .scanning:
                return "Reviewing for missed obligations (final pass)"
            }
        }
        return isLoading ? "Preparing scan" : "Coverage check ready"
    }

    var progressSliceText: String? {
        guard let resume = latestResumeState else { return nil }
        let totalMonths = max(resume.totalMonths, 1)
        switch resume.phase {
        case .backfill:
            let current = min(max(resume.monthIndex + 1, 1), totalMonths)
            return "Month \(current) of \(totalMonths)"
        case .scanning:
            return "Final review after \(totalMonths) monthly slices"
        }
    }

    var progressDetail: String {
        if isInProgress, let progressFraction, progressFraction >= 0.99 {
            return "99% complete • Finalizing results and promoting to Now/Later..."
        }
        if let progressPercentageText {
            if scannedMessageCount > 0 {
                if let progressSliceText {
                    return "\(progressPercentageText) • \(progressSliceText) • \(scannedMessageCount) messages scanned"
                }
                return "\(progressPercentageText) • \(scannedMessageCount) messages scanned"
            }
            if let progressSliceText {
                return "\(progressPercentageText) • \(progressSliceText)"
            }
            return progressPercentageText
        }
        if scannedMessageCount > 0 {
            return "\(scannedMessageCount) messages scanned"
        }
        return "This can take a few minutes for large inboxes."
    }

    var pausedAtText: String? {
        guard let lastPaused else { return nil }
        return lastPaused.formatted(date: .abbreviated, time: .shortened)
    }

    var progressPercentageText: String? {
        guard let progressFraction else { return nil }
        let percent: Int
        if isInProgress {
            percent = Int((progressFraction * 100).rounded(.down))
        } else {
            percent = Int((progressFraction * 100).rounded())
        }
        return "\(percent)% complete"
    }
    
    var throttleReasonText: String? {
        guard let reason = latestResumeState?.lastThrottleReason?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reason.isEmpty else {
            return nil
        }
        switch reason {
        case "memory": return "Memory pressure"
        case "thermal": return "Thermal pressure"
        case "lowPower": return "Low Power Mode"
        case "recovery": return "Recovery mode"
        default: return reason.capitalized
        }
    }
    
    var throttleMemoryText: String? {
        guard let bytes = latestResumeState?.lastKnownMemoryBytes, bytes > 0 else { return nil }
        let mb = bytes / 1_000_000
        return "\(mb) MB"
    }
    
    var throttleThermalText: String? {
        guard let thermal = latestResumeState?.lastKnownThermalState?.trimmingCharacters(in: .whitespacesAndNewlines),
              !thermal.isEmpty else {
            return nil
        }
        return thermal.capitalized
    }
    
    var throttleBatchText: String? {
        guard let batch = latestResumeState?.lastKnownBatchSize, batch > 0 else { return nil }
        return "\(batch) messages/page"
    }

    var droppedDiagnosticsText: String? {
        guard !droppedReasonCounts.isEmpty else { return nil }
        let order: [LongScanPromotionReasonCode] = [.suppressed, .lowConfidence, .missingDueDate]
        let chunks = order.compactMap { code -> String? in
            guard let count = droppedReasonCounts[code], count > 0 else { return nil }
            let label: String
            switch code {
            case .suppressed:
                label = "suppressed"
            case .lowConfidence:
                label = "low confidence"
            case .missingDueDate:
                label = "missing due date"
            default:
                label = code.rawValue.replacingOccurrences(of: "_", with: " ")
            }
            return "\(label): \(count)"
        }
        guard !chunks.isEmpty else { return nil }
        return chunks.joined(separator: " • ")
    }

    var canResume: Bool {
        if case .paused = uiState {
            return latestResumeState != nil || isInProgress
        }
        return false
    }

    var canPause: Bool {
        if case .running = uiState {
            return scanTask != nil
        }
        return false
    }

    var canCancel: Bool {
        switch uiState {
        case .running, .paused:
            return true
        default:
            return false
        }
    }

    var displayErrorMessage: String {
        CoverageStatusPresenter.errorMessage(for: CoverageStatusPresenter.displayError(from: error))
    }

    deinit {
        scanTask?.cancel()
    }

    func startScan(using environment: AppEnvironment, userInitiated: Bool = false) {
        guard scanTask == nil else { return }
        guard userInitiated || environment.syncPolicyStore.longScanAndBackgroundOptIn else {
            let months = environment.syncPolicyStore.coverageScanMonths
            statusMessage = "Enable long scans in Sync Policy to run a \(months)-month coverage scan."
            isInProgress = false
            updateUIState()
            return
        }
        if !userInitiated && environment.syncPolicyStore.longScanAndBackgroundOptIn {
            YearScanBackgroundManager.scheduleBackfill(
                requiresCharging: environment.syncPolicyStore.coverageBackgroundRequiresCharging
            )
        }
        progressFraction = 0.02
        scanTask = Task {
            await runScan(using: environment, resume: false)
            scanTask = nil
        }
        updateUIState()
    }

    func restartScan(using environment: AppEnvironment, userInitiated: Bool = false) {
        scanTask?.cancel()
        scanTask = nil
        latestResumeState = nil
        startScan(using: environment, userInitiated: userInitiated)
    }

    func resumeScan(using environment: AppEnvironment) {
        guard scanTask == nil else { return }
        scanTask = Task {
            await runScan(using: environment, resume: true)
            scanTask = nil
        }
        updateUIState()
    }

    func pauseScan(using environment: AppEnvironment) {
        guard scanTask != nil else { return }
        scanTask?.cancel()
        scanTask = nil
        isLoading = false
        isInProgress = true
        statusMessage = "Scan paused. Resume whenever you're ready."
        Task {
            await YearScanCoordinator.persistPaused(
                environment: environment,
                scannedMessageCount: scannedMessageCount,
                statusMessage: statusMessage,
                resumeState: latestResumeState,
                configuration: YearScanRunner.RunConfiguration.from(policy: environment.syncPolicyStore)
            )
        }
        updateUIState()
    }

    func cancelScan(using environment: AppEnvironment) {
        scanTask?.cancel()
        scanTask = nil
        activeRunToken = nil
        partialSequence = 0
        isLoading = false
        isInProgress = false
        statusMessage = "Scan cancelled."
        progressFraction = nil
        latestResumeState = nil
        Task {
            await YearScanCoordinator.clearResumeState(environment: environment)
        }
        updateUIState()
    }

    func loadCached(using environment: AppEnvironment) async {
        guard !isLoading else { return }
        if let snapshot = try? await environment.yearScanRepository.fetchLatest() {
            results = snapshot.items
            expectedEventSignals = snapshot.expectedEventSignals
            droppedReasonCounts = snapshot.droppedReasonCounts
            lastChecked = snapshot.lastChecked
            lastPaused = snapshot.lastPaused
            scannedMessageCount = snapshot.scannedMessageCount
            coverageSummary = snapshot.coverageSummary
            isInProgress = snapshot.isInProgress
            statusMessage = snapshot.statusMessage
            latestResumeState = snapshot.resumeState
            monthSummaries = snapshot.resumeState?.monthSummaries ?? []
            estimatedScanMessages = max(estimatedScanMessages ?? 0, snapshot.scannedMessageCount)
            updateProgress()
            updateUIState()
        }
    }

    func runScan(using environment: AppEnvironment, resume: Bool) async {
        let runConfiguration = YearScanRunner.RunConfiguration.from(policy: environment.syncPolicyStore)
        let runToken = UUID().uuidString
        activeRunToken = runToken
        partialSequence = 0
        isLoading = true
        error = nil
        if !resume {
            scannedMessageCount = 0
            latestResumeState = nil
            progressFraction = 0.02
            expectedEventSignals = []
            droppedReasonCounts = [:]
            monthSummaries = []
        }
        statusMessage = resume ? "Resuming scan..." : "Preparing scan..."
        isInProgress = true
        defer {
            isLoading = false
            updateUIState()
        }
        await YearScanCoordinator.persistInProgress(
            environment: environment,
            scannedMessageCount: scannedMessageCount,
            statusMessage: statusMessage,
            resumeState: latestResumeState,
            configuration: runConfiguration
        )

        do {
            let accounts = try await environment.mailboxAccountRepository.fetchAll()
            accountsById = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
            let resumeState: YearScanResumeState?
            if resume {
                if let latestResumeState {
                    resumeState = latestResumeState
                } else {
                    resumeState = try await environment.yearScanRepository.fetchResumeState()
                }
            } else {
                resumeState = nil
            }

            let runResult = try await YearScanCoordinator.run(
                environment: environment,
                resumeState: resumeState,
                configuration: runConfiguration,
                statusUpdate: { status in
                    Task { @MainActor in
                        guard self.activeRunToken == runToken else { return }
                        self.statusMessage = CoverageStatusPresenter.progressMessage(from: status)
                        self.isInProgress = true
                        if let count = Self.extractScannedCount(from: status) {
                            self.scannedMessageCount = count
                        }
                    }
                },
                checkpointUpdate: { checkpoint in
                    Task { @MainActor in
                        guard self.activeRunToken == runToken else { return }
                        self.latestResumeState = checkpoint
                        self.monthSummaries = checkpoint.monthSummaries ?? []
                        self.updateProgress()
                        self.partialSequence += 1
                        let sequence = self.partialSequence
                        let scanRange = runConfiguration.rangeMonths
                        let scanIntensity = runConfiguration.intensity.rawValue
                        let scannedCount = self.scannedMessageCount
                        let status = self.statusMessage
                        Task {
                            try? await environment.yearScanRepository.upsertPartial(
                                items: [],
                                scannedMessageCount: scannedCount,
                                coverageSummary: self.coverageSummary,
                                statusMessage: status,
                                resumeState: checkpoint,
                                scanRangeMonths: scanRange,
                                scanIntensity: scanIntensity,
                                excludedProviderMessageIds: [],
                                runToken: runToken,
                                sequence: sequence
                            )
                        }
                    }
                },
                partialUpdate: { update in
                    Task { @MainActor in
                        guard self.activeRunToken == runToken else { return }
                        self.partialSequence += 1
                        let sequence = self.partialSequence
                        self.applyPartialUpdate(update)
                        let scanRange = runConfiguration.rangeMonths
                        let scanIntensity = runConfiguration.intensity.rawValue
                        let coverageSummary = self.coverageSummary
                        Task {
                            let excluded = (try? await environment.messageStateManager.getExcludedMessageIDsCached(maxAge: 3.0)) ?? []
                            try? await environment.yearScanRepository.upsertPartial(
                                items: update.items,
                                scannedMessageCount: update.scannedMessageCount,
                                coverageSummary: coverageSummary,
                                statusMessage: update.statusMessage,
                                resumeState: update.resumeState,
                                scanRangeMonths: scanRange,
                                scanIntensity: scanIntensity,
                                excludedProviderMessageIds: excluded,
                                runToken: runToken,
                                sequence: sequence
                            )
                        }
                    }
                }
            )

            let promotedItems = runResult.items.filter { $0.promotionDecision == .promoted }
            results = promotedItems
            expectedEventSignals = runResult.items
                .filter { $0.promotionDecision == .expectedEvent }
                .map {
                    ExpectedEventPatternSignal(
                        mailboxAccountId: $0.mailboxAccountId,
                        threadId: $0.threadId,
                        providerMessageId: $0.providerMessageId,
                        subject: $0.subject,
                        snippet: $0.snippet,
                        confidence: $0.confidence,
                        dueDate: $0.dueDate,
                        reasonCode: $0.promotionReasonCode,
                        source: $0.source,
                        detectedAt: $0.detectedAt
                    )
                }
            droppedReasonCounts = runResult.items
                .filter { $0.promotionDecision == .dropped }
                .reduce(into: [LongScanPromotionReasonCode: Int]()) { counts, item in
                    counts[item.promotionReasonCode, default: 0] += 1
                }
            scannedMessageCount = runResult.scannedMessageCount
            lastChecked = Date()
            lastPaused = nil
            statusMessage = nil
            isInProgress = false
            latestResumeState = nil
            monthSummaries = []
            progressFraction = 1.0
            activeRunToken = nil
            partialSequence = 0
            updateUIState()

            let excluded = (try? await environment.messageStateManager.getExcludedMessageIDsCached(maxAge: 0)) ?? []
            try await environment.yearScanRepository.saveRun(
                items: runResult.items,
                scannedMessageCount: runResult.scannedMessageCount,
                lastChecked: lastChecked,
                coverageSummary: coverageSummary,
                scanRangeMonths: runConfiguration.rangeMonths,
                scanIntensity: runConfiguration.intensity.rawValue,
                excludedProviderMessageIds: excluded
            )
            await YearScanCoordinator.bridgePromotedFindingsToObligations(
                environment: environment,
                items: runResult.items
            )
        } catch let quotaErr as YearScanQuotaStoppedError {
            self.error = quotaErr
            latestResumeState = quotaErr.resumeState
            monthSummaries = quotaErr.resumeState.monthSummaries ?? []
            if quotaErr.resumeState.consecutiveQuotaHits >= 2 {
                statusMessage = "Paused due to repeated Gmail API limits. Wait a bit, then resume."
            } else if quotaErr.lastCompletedMonthIndex < 0 {
                statusMessage = "Paused due to Gmail API limit before month 1. Resume later."
            } else {
                let done = quotaErr.lastCompletedMonthIndex + 1
                statusMessage = "Paused at month \(done) of \(quotaErr.totalMonths) due to Gmail API limit."
            }
            isInProgress = true
            updateProgress()
            updateUIState()
            activeRunToken = nil
            Logger.info("YearScan: quota stopped month=\(quotaErr.lastCompletedMonthIndex + 1)/\(quotaErr.totalMonths)")
            await YearScanCoordinator.persistPaused(
                environment: environment,
                scannedMessageCount: scannedMessageCount,
                statusMessage: statusMessage,
                resumeState: latestResumeState,
                configuration: runConfiguration
            )
        } catch is CancellationError {
            isInProgress = true
            statusMessage = "Scan paused. Resume whenever you're ready."
            monthSummaries = latestResumeState?.monthSummaries ?? []
            updateProgress()
            updateUIState()
            activeRunToken = nil
            await YearScanCoordinator.persistPaused(
                environment: environment,
                scannedMessageCount: scannedMessageCount,
                statusMessage: statusMessage,
                resumeState: latestResumeState,
                configuration: runConfiguration
            )
        } catch {
            self.error = error
            statusMessage = "Scan failed. Try again."
            isInProgress = false
            updateProgress()
            updateUIState()
            activeRunToken = nil
            Logger.info("YearScan: failed \(error)")
        }
    }

    func clearError() {
        error = nil
        updateUIState()
    }

    func dismiss(_ item: YearScanItem) {
        results.removeAll { $0.id == item.id }
    }

    func providerURL(for item: YearScanItem) -> URL? {
        let account = accountsById[item.mailboxAccountId]
        if account?.provider == .gmail {
            let trimmedThreadId = item.threadId?.trimmingCharacters(in: .whitespacesAndNewlines)
            let target = (trimmedThreadId?.isEmpty == false ? trimmedThreadId : nil) ?? item.providerMessageId
            let encodedTarget = target.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target
            return URL(string: "https://mail.google.com/mail/u/0/#all/\(encodedTarget)")
        }
        return nil
    }

    private static func extractScannedCount(from status: String) -> Int? {
        let pattern = #"Scanning inbox\.\.\. ([0-9]+) messages"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let nsRange = NSRange(status.startIndex..<status.endIndex, in: status)
        guard let match = regex.firstMatch(in: status, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: status) else {
            return nil
        }
        return Int(status[range])
    }

    private func applyPartialUpdate(_ update: YearScanPartialUpdate) {
        latestResumeState = update.resumeState
        monthSummaries = update.resumeState.monthSummaries ?? []
        scannedMessageCount = update.scannedMessageCount
        statusMessage = CoverageStatusPresenter.progressMessage(from: update.statusMessage)
        isInProgress = true

        let promotedItems = update.items.filter { $0.promotionDecision == .promoted }
        results = promotedItems
        expectedEventSignals = update.items
            .filter { $0.promotionDecision == .expectedEvent }
            .map {
                ExpectedEventPatternSignal(
                    mailboxAccountId: $0.mailboxAccountId,
                    threadId: $0.threadId,
                    providerMessageId: $0.providerMessageId,
                    subject: $0.subject,
                    snippet: $0.snippet,
                    confidence: $0.confidence,
                    dueDate: $0.dueDate,
                    reasonCode: $0.promotionReasonCode,
                    source: $0.source,
                    detectedAt: $0.detectedAt
                )
            }
        droppedReasonCounts = update.items
            .filter { $0.promotionDecision == .dropped }
            .reduce(into: [LongScanPromotionReasonCode: Int]()) { counts, item in
                counts[item.promotionReasonCode, default: 0] += 1
            }
        updateProgress()
        updateUIState()
    }
    
    private func updateProgress() {
        guard let state = latestResumeState else {
            if isLoading {
                progressFraction = max(progressFraction ?? 0.02, 0.02)
            } else if !isInProgress {
                progressFraction = nil
            }
            return
        }

        switch state.phase {
        case .backfill:
            let totalMonths = max(state.totalMonths, 1)
            let totalSlices = max(totalMonths + 1, 1)
            let completedSlices = min(max(state.monthIndex, 0), totalMonths)
            progressFraction = Double(completedSlices) / Double(totalSlices)
        case .scanning:
            let totalMonths = max(state.totalMonths, 1)
            let totalSlices = max(totalMonths + 1, 1)
            let completedBase = Double(totalMonths) / Double(totalSlices)
            let scanned = max(state.scannedMessageCount, scannedMessageCount)
            if let estimate = estimatedScanMessages {
                estimatedScanMessages = max(estimate, scanned)
            } else {
                estimatedScanMessages = max(scanned + 1000, 2000)
            }
            let estimate = max(estimatedScanMessages ?? 2000, 1)
            let scanCompletion = min(1.0, Double(scanned) / Double(estimate))
            let finalSliceWeight = 1.0 / Double(totalSlices)
            progressFraction = completedBase + (finalSliceWeight * scanCompletion)
        }

        if let progressFraction {
            let clamped = min(max(progressFraction, 0.0), 1.0)
            // Keep in-progress UX truthful: reserve 100% for completed state.
            self.progressFraction = isInProgress ? min(clamped, 0.99) : clamped
        }
    }

    private func updateUIState() {
        uiState = Self.deriveUIState(
            isLoading: isLoading,
            hasError: error != nil,
            isInProgress: isInProgress,
            hasResults: !results.isEmpty,
            lastChecked: lastChecked,
            scannedMessageCount: scannedMessageCount
        )
    }

    static func deriveUIState(
        isLoading: Bool,
        hasError: Bool,
        isInProgress: Bool,
        hasResults: Bool,
        lastChecked: Date?,
        scannedMessageCount: Int
    ) -> CoverageUIState {
        if isLoading {
            return .running
        }
        if hasError {
            return .failed
        }
        if isInProgress {
            return .paused
        }
        if hasResults {
            return .completed(hasFindings: true)
        }
        if lastChecked != nil {
            return .completed(hasFindings: false)
        }
        return .idle(needsConnection: false)
    }
}
