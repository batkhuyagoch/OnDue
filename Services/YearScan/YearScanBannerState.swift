import SwiftUI
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
            return "Network issue while searching. Try again when your connection is stable."
        case .generic:
            return "Deep scan failed. Try again."
        }
    }

    static func title(for state: CoverageUIState) -> String {
        switch state {
        case .idle(let needsConnection):
            return needsConnection ? "Connect Gmail to start a deep scan" : "Find past obligations"
        case .running:
            return "Deep scan running"
        case .paused:
            return "Deep scan paused"
        case .completed(let hasFindings):
            return hasFindings ? "Deep scan found items" : "Deep scan complete"
        case .failed:
            return "Deep scan failed"
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

struct YearScanBanner: View {
    @ObservedObject var state: YearScanState
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @State private var isDismissed = false
    @State private var showScanHistory = false

    var body: some View {
        if !isDismissed {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: state.isScanning ? "arrow.clockwise" : "calendar.badge.clock")
                        .font(.title2)
                        .foregroundStyle(state.isScanning ? .blue : .orange)
                        .symbolEffect(.pulse, isActive: state.isScanning)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.bannerTitle)
                            .font(.subheadline.weight(.semibold))

                        Text(state.bannerSubtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if state.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else if state.unseenItemsCount > 0 {
                        Button {
                            showScanHistory = true
                        } label: {
                            Text("Review")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.blue, in: Capsule())
                        }
                    } else {
                        Button {
                            Task {
                                await state.startScan(using: environmentStore.value)
                            }
                        } label: {
                            Text("Scan")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.blue, in: Capsule())
                        }
                    }

                    if !state.isScanning {
                        Button {
                            withAnimation {
                                isDismissed = true
                            }
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .background(.ultraThinMaterial)

                if state.isScanning, let progress = state.scanProgress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(.blue)
                }
            }
            .background(Color(.systemBackground))
            .shadow(radius: 2)
            .sheet(isPresented: $showScanHistory) {
                NavigationStack {
                    YearScanHistoryView()
                }
                .environmentObject(environmentStore)
            }
        }
    }
}

struct ScanSnapshot: Equatable {
    var lastScanDate: Date?
    var isScanning = false
    var scanProgress: Double?
    var foundItemsCount = 0
    var unseenItemsCount = 0
    var scannedMessageCount = 0
    var scanStatusMessage: String?
    var livePromotedPreview: [YearScanItem] = []
    var liveDeltaCount: Int = 0
    var currentPhase: YearScanPhase?
    var currentMonthIndex: Int?
    var totalMonths: Int?
    var monthSummaries: [YearScanMonthSummary] = []
}

@MainActor
class YearScanState: ObservableObject {
    @Published var snapshot = ScanSnapshot()
    private var estimatedScanMessages: Int?
    private var latestResumeState: YearScanResumeState?
    private var scanTask: Task<Void, Never>?
    private var pauseRequested = false
    private var cancelRequested = false

    var lastScanDate: Date? {
        get { snapshot.lastScanDate }
        set { snapshot.lastScanDate = newValue }
    }
    var isScanning: Bool {
        get { snapshot.isScanning }
        set { snapshot.isScanning = newValue }
    }
    var scanProgress: Double? {
        get { snapshot.scanProgress }
        set { snapshot.scanProgress = newValue }
    }
    var foundItemsCount: Int {
        get { snapshot.foundItemsCount }
        set { snapshot.foundItemsCount = newValue }
    }
    var unseenItemsCount: Int {
        get { snapshot.unseenItemsCount }
        set { snapshot.unseenItemsCount = newValue }
    }
    var scannedMessageCount: Int {
        get { snapshot.scannedMessageCount }
        set { snapshot.scannedMessageCount = newValue }
    }
    var scanStatusMessage: String? {
        get { snapshot.scanStatusMessage }
        set { snapshot.scanStatusMessage = newValue }
    }
    var livePromotedPreview: [YearScanItem] {
        get { snapshot.livePromotedPreview }
        set { snapshot.livePromotedPreview = newValue }
    }
    var liveDeltaCount: Int {
        get { snapshot.liveDeltaCount }
        set { snapshot.liveDeltaCount = newValue }
    }
    var currentPhase: YearScanPhase? {
        get { snapshot.currentPhase }
        set { snapshot.currentPhase = newValue }
    }
    var currentMonthIndex: Int? {
        get { snapshot.currentMonthIndex }
        set { snapshot.currentMonthIndex = newValue }
    }
    var totalMonths: Int? {
        get { snapshot.totalMonths }
        set { snapshot.totalMonths = newValue }
    }
    var monthSummaries: [YearScanMonthSummary] {
        get { snapshot.monthSummaries }
        set { snapshot.monthSummaries = newValue }
    }

    var canPause: Bool {
        isScanning && scanTask != nil
    }

    var canResume: Bool {
        !isScanning && latestResumeState != nil
    }

    var canCancel: Bool {
        isScanning || latestResumeState != nil
    }

    var shouldShowBanner: Bool {
        if isScanning { return true }
        if unseenItemsCount > 0 { return true }

        guard let lastScan = lastScanDate else {
            return true
        }

        let daysSince = Calendar.current.dateComponents([.day], from: lastScan, to: Date()).day ?? 0
        return daysSince > 7
    }

    var bannerTitle: String {
        if isScanning {
            return "Deep scan running…"
        } else if lastScanDate == nil {
            return "Find past obligations"
        } else if unseenItemsCount > 0 {
            return "Found \(unseenItemsCount) items"
        } else {
            let daysSince = Calendar.current.dateComponents([.day], from: lastScanDate!, to: Date()).day ?? 0
            return "Last scanned \(daysSince) days ago"
        }
    }

    var bannerSubtitle: String {
        if isScanning {
            if isFinalizing {
                return "Finalizing results and promoting to Now/Later..."
            }
            if let scanStatusMessage, !scanStatusMessage.isEmpty {
                return scanStatusMessage
            }
            return scannedMessageCount > 0 ? "Reviewed \(scannedMessageCount) messages" : "Starting scan..."
        } else if lastScanDate == nil {
            return "We haven't scanned your past emails yet"
        } else if unseenItemsCount > 0 {
            return "Tap to review what we found"
        } else {
            return "Scan again to check for new obligations"
        }
    }

    var isFinalizing: Bool {
        guard isScanning, let scanProgress else { return false }
        return scanProgress >= 0.99
    }

    var resumePointText: String? {
        guard isScanning else { return nil }
        guard let currentPhase else { return nil }
        switch currentPhase {
        case .backfill:
            let monthLabel = monthSummaries.first(where: { $0.isInProgress })?.monthLabel
            if let monthLabel {
                return "Resuming at \(monthLabel)"
            }
            if let currentMonthIndex, let totalMonths {
                return "Resuming at month \(currentMonthIndex + 1) of \(totalMonths)"
            }
            return nil
        case .scanning:
            return "Resuming final review pass"
        }
    }

    func loadStatus(using environment: AppEnvironment) async {
        do {
            if let repoSnapshot = try await environment.yearScanRepository.fetchLatest() {
                var s = ScanSnapshot()
                s.lastScanDate = repoSnapshot.lastChecked
                s.foundItemsCount = repoSnapshot.items.count
                s.unseenItemsCount = repoSnapshot.items.count
                s.scannedMessageCount = repoSnapshot.scannedMessageCount
                s.scanStatusMessage = repoSnapshot.statusMessage
                s.livePromotedPreview = Array(repoSnapshot.items.prefix(5))
                if let resume = repoSnapshot.resumeState {
                    s.currentPhase = resume.phase
                    s.currentMonthIndex = resume.monthIndex
                    s.totalMonths = resume.totalMonths
                    s.monthSummaries = resume.monthSummaries ?? []
                    latestResumeState = resume
                } else {
                    latestResumeState = nil
                }

                if repoSnapshot.isInProgress {
                    if let updatedAt = repoSnapshot.updatedAt {
                        let timeSinceUpdate = Date().timeIntervalSince(updatedAt)
                        s.isScanning = timeSinceUpdate < 300
                    }
                }
                snapshot = s

                if repoSnapshot.isInProgress {
                    if let updatedAt = repoSnapshot.updatedAt {
                        let timeSinceUpdate = Date().timeIntervalSince(updatedAt)
                        if timeSinceUpdate < 300, let resumeState = repoSnapshot.resumeState {
                            updateProgress(from: resumeState)
                        }
                        if timeSinceUpdate >= 300 {
                            try? await environment.yearScanRepository.clearResumeState()
                        }
                    } else {
                        snapshot.isScanning = false
                        try? await environment.yearScanRepository.clearResumeState()
                    }
                }
            }
        } catch {
            snapshot = ScanSnapshot()
        }
    }

    func startScan(using environment: AppEnvironment) async {
        guard scanTask == nil else { return }
        pauseRequested = false
        cancelRequested = false
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runScan(using: environment, resumeState: nil)
        }
        scanTask = task
        await task.value
        scanTask = nil
    }

    func resumeScan(using environment: AppEnvironment) async {
        guard scanTask == nil else { return }
        guard let resume = latestResumeState else {
            await startScan(using: environment)
            return
        }
        pauseRequested = false
        cancelRequested = false
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runScan(using: environment, resumeState: resume)
        }
        scanTask = task
        await task.value
        scanTask = nil
    }

    func pauseScan(using environment: AppEnvironment) async {
        guard canPause else { return }
        pauseRequested = true
        scanTask?.cancel()
        scanTask = nil
        let configuration = YearScanRunner.RunConfiguration.from(policy: environment.syncPolicyStore)
        await finalizeAfterScanFailure(
            environment: environment,
            configuration: configuration,
            statusMessage: "Scan paused. Resume whenever you're ready."
        )
    }

    func cancelScan(using environment: AppEnvironment) async {
        cancelRequested = true
        pauseRequested = false
        scanTask?.cancel()
        scanTask = nil
        snapshot = ScanSnapshot(scanStatusMessage: "Scan canceled.")
        latestResumeState = nil
        try? await environment.yearScanRepository.clearResumeState()
    }

    private func runScan(
        using environment: AppEnvironment,
        resumeState: YearScanResumeState?
    ) async {
        let runStartedAt = Date()
        var lastCheckpointUIUpdate = Date.distantPast
        var lastCheckpointPersistAt = Date.distantPast
        let isResuming = resumeState != nil
        // Preserve the count of items found before this resume so partialUpdate
        // and the final snapshot can display the running total correctly.
        let preResumeFoundCount = isResuming ? foundItemsCount : 0
        if resumeState == nil {
            snapshot = ScanSnapshot(isScanning: true, scanProgress: 0, scanStatusMessage: "Preparing scan...")
            latestResumeState = nil
        } else {
            var s = snapshot
            s.isScanning = true
            s.scanStatusMessage = "Resuming scan..."
            s.currentPhase = resumeState?.phase
            s.currentMonthIndex = resumeState?.monthIndex
            s.totalMonths = resumeState?.totalMonths
            s.monthSummaries = resumeState?.monthSummaries ?? s.monthSummaries
            snapshot = s
            latestResumeState = resumeState
            if let resumeState {
                updateProgress(from: resumeState)
            }
        }
        let policyConfiguration = YearScanRunner.RunConfiguration.from(policy: environment.syncPolicyStore)
        let resumeRangeMonths = resumeState?.configuredRangeMonths ?? policyConfiguration.rangeMonths
        let resumeIntensity = resumeState?.configuredIntensity
            .flatMap(CoverageScanIntensity.init(rawValue:))
            ?? policyConfiguration.intensity
        let runConfiguration = YearScanRunner.RunConfiguration(
            rangeMonths: SyncPolicyStore.clampCoverageMonths(
                resumeRangeMonths,
                max: environment.syncPolicyStore.effectiveMaximumCoverageMonths
            ),
            intensity: resumeIntensity
        )
        let restoredSession = (try? await environment.gmailAuthService.restorePreviousSignIn()) ?? false
        guard restoredSession else {
            var s = snapshot
            s.isScanning = false
            s.scanProgress = nil
            s.scanStatusMessage = "Gmail session expired. Reconnect Gmail in Settings to run scan."
            snapshot = s
            return
        }

        do {
            let runToken = UUID().uuidString
            var partialSequence = 0
            await YearScanRunner.persistInProgress(
                environment: environment,
                scannedMessageCount: scannedMessageCount,
                statusMessage: scanStatusMessage,
                resumeState: resumeState,
                configuration: runConfiguration
            )
            let result = try await YearScanRunner.run(
                environment: environment,
                resumeState: resumeState,
                configuration: runConfiguration,
                statusUpdate: { [weak self] status in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.scanStatusMessage = CoverageStatusPresenter.progressMessage(from: status)
                        if let count = YearScanBackgroundManager.scannedCount(from: status) {
                            self.scannedMessageCount = count
                        }
                    }
                },
                checkpointUpdate: { [weak self] checkpoint in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.shouldApplyIncomingResumeState(checkpoint) else { return }
                        self.latestResumeState = checkpoint

                        let now = Date()
                        if now.timeIntervalSince(lastCheckpointUIUpdate) >= 0.5 {
                            lastCheckpointUIUpdate = now
                            var s = self.snapshot
                            s.scannedMessageCount = checkpoint.scannedMessageCount
                            s.currentPhase = checkpoint.phase
                            s.currentMonthIndex = checkpoint.monthIndex
                            s.totalMonths = checkpoint.totalMonths
                            s.monthSummaries = checkpoint.monthSummaries ?? []
                            self.snapshot = s
                            self.updateProgress(from: checkpoint)
                        }

                        if now.timeIntervalSince(lastCheckpointPersistAt) >= 3.0 {
                            lastCheckpointPersistAt = now
                            partialSequence += 1
                            let sequence = partialSequence
                            Task {
                                try? await environment.yearScanRepository.upsertPartial(
                                    items: [],
                                    scannedMessageCount: checkpoint.scannedMessageCount,
                                    coverageSummary: YearScanRunner.coverageSummary,
                                    statusMessage: checkpoint.lastStatusMessage,
                                    resumeState: checkpoint,
                                    scanRangeMonths: runConfiguration.rangeMonths,
                                    scanIntensity: runConfiguration.intensity.rawValue,
                                    excludedProviderMessageIds: [],
                                    runToken: runToken,
                                    sequence: sequence
                                )
                            }
                        }
                    }
                },
                partialUpdate: { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        guard self.shouldApplyIncomingResumeState(update.resumeState) else { return }
                        let previousCount = self.foundItemsCount
                        let newlyPromotedCount = update.items.filter { $0.promotionDecision == .promoted }.count
                        let totalCount = preResumeFoundCount + newlyPromotedCount
                        var s = self.snapshot
                        s.scannedMessageCount = update.scannedMessageCount
                        s.scanStatusMessage = CoverageStatusPresenter.progressMessage(from: update.statusMessage)
                        s.currentPhase = update.resumeState.phase
                        s.currentMonthIndex = update.resumeState.monthIndex
                        s.totalMonths = update.resumeState.totalMonths
                        s.monthSummaries = update.resumeState.monthSummaries ?? []
                        s.foundItemsCount = totalCount
                        s.unseenItemsCount = totalCount
                        s.liveDeltaCount = max(0, totalCount - previousCount)
                        s.livePromotedPreview = Array(
                            update.items
                                .filter { $0.promotionDecision == .promoted }
                                .sorted { $0.detectedAt > $1.detectedAt }
                                .prefix(5)
                        )
                        self.snapshot = s
                        self.latestResumeState = update.resumeState
                        self.updateProgress(from: update.resumeState)
                        partialSequence += 1
                        let sequence = partialSequence
                        Task {
                            let excluded = (try? await environment.messageStateManager.getExcludedMessageIDsCached(maxAge: 3.0)) ?? []
                            try? await environment.yearScanRepository.upsertPartial(
                                items: update.items,
                                scannedMessageCount: update.scannedMessageCount,
                                coverageSummary: YearScanRunner.coverageSummary,
                                statusMessage: update.statusMessage,
                                resumeState: update.resumeState,
                                scanRangeMonths: runConfiguration.rangeMonths,
                                scanIntensity: runConfiguration.intensity.rawValue,
                                excludedProviderMessageIds: excluded,
                                runToken: runToken,
                                sequence: sequence
                            )
                        }
                    }
                }
            )

            let totalFoundCount = preResumeFoundCount + result.items.count
            snapshot = ScanSnapshot(
                lastScanDate: Date(),
                foundItemsCount: totalFoundCount,
                unseenItemsCount: totalFoundCount,
                livePromotedPreview: Array(
                    result.items
                        .filter { $0.promotionDecision == .promoted }
                        .sorted { $0.detectedAt > $1.detectedAt }
                        .prefix(5)
                )
            )
            latestResumeState = nil
            await environment.yearScanRepository.markRunFinalized(runToken: runToken)
            let excluded = (try? await environment.messageStateManager.getExcludedMessageIDsCached(maxAge: 0)) ?? []
            try? await environment.yearScanRepository.saveRun(
                items: result.items,
                scannedMessageCount: result.scannedMessageCount,
                lastChecked: lastScanDate,
                coverageSummary: YearScanRunner.coverageSummary,
                scanRangeMonths: runConfiguration.rangeMonths,
                scanIntensity: runConfiguration.intensity.rawValue,
                excludedProviderMessageIds: excluded,
                mergeWithExisting: isResuming
            )
            await YearScanRunner.bridgePromotedFindingsToObligations(
                environment: environment,
                items: result.items
            )
            AppLog.info(
                "YearScanBanner.startScan.completed",
                fields: [
                    "stopReason": result.telemetry.stopReason,
                    "elapsedSeconds": String(format: "%.2f", result.telemetry.elapsedSeconds),
                    "peakMemoryMB": result.telemetry.peakMemoryMB,
                    "pagesScanned": result.telemetry.pagesScanned,
                    "effectiveBatchSize": result.telemetry.effectiveBatchSize,
                    "scanRangeMonths": runConfiguration.rangeMonths
                ]
            )
        } catch let quota as YearScanQuotaStoppedError {
            latestResumeState = quota.resumeState
            var s = snapshot
            s.currentPhase = quota.resumeState.phase
            s.currentMonthIndex = quota.resumeState.monthIndex
            s.totalMonths = quota.resumeState.totalMonths
            s.monthSummaries = quota.resumeState.monthSummaries ?? []
            snapshot = s
            await finalizeAfterScanFailure(
                environment: environment,
                configuration: runConfiguration,
                statusMessage: "Scan paused due to Gmail API limits. Resume when ready."
            )
            AppLog.info(
                "YearScanBanner.startScan.quotaStopped",
                fields: [
                    "monthIndex": quota.resumeState.monthIndex,
                    "totalMonths": quota.resumeState.totalMonths,
                    "scanRangeMonths": runConfiguration.rangeMonths
                ]
            )
        } catch {
            if Task.isCancelled {
                if cancelRequested {
                    cancelRequested = false
                    pauseRequested = false
                    return
                }
                if pauseRequested {
                    pauseRequested = false
                    return
                }
            }
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                let stopReason = AppErrorClassifier.classLabel(for: error)
                AppLog.debug(
                    "YearScanBanner.startScan.suppressed",
                    fields: [
                        "errorClass": stopReason,
                        "error": error.localizedDescription
                    ]
                )
                await finalizeAfterScanFailure(
                    environment: environment,
                    configuration: runConfiguration,
                    statusMessage: "Scan paused. Resume whenever you're ready."
                )
                AppLog.info(
                    "YearScanBanner.startScan.stopped",
                    fields: [
                        "stopReason": stopReason,
                        "elapsedSeconds": String(format: "%.2f", Date().timeIntervalSince(runStartedAt)),
                        "scanRangeMonths": runConfiguration.rangeMonths
                    ]
                )
                return
            }
            AppLog.error(
                "YearScanBanner.startScan.failed",
                fields: [
                    "stopReason": AppErrorClassifier.classLabel(for: error),
                    "elapsedSeconds": String(format: "%.2f", Date().timeIntervalSince(runStartedAt)),
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            let message: String
            if Self.isAuthenticationError(error) {
                message = "Gmail authorization expired. Reconnect Gmail in Settings."
            } else {
                message = AppUserErrorMapper.message(for: error, fallback: "Scan failed. Try again.")
            }
            await finalizeAfterScanFailure(
                environment: environment,
                configuration: runConfiguration,
                statusMessage: message
            )
            print("Scan error: \(error)")
        }
    }

    private static func isAuthenticationError(_ error: Error) -> Bool {
        if case GmailClientError.apiError(let code, let message) = error {
            if code == 401 { return true }
            return code == 403 && message.lowercased().contains("auth")
        }
        if case GmailClientError.notAuthenticated = error {
            return true
        }
        let description = error.localizedDescription.lowercased()
        return description.contains("invalid credentials") || description.contains("unauthenticated")
    }

    private func finalizeAfterScanFailure(
        environment: AppEnvironment,
        configuration: YearScanRunner.RunConfiguration,
        statusMessage: String
    ) async {
        var s = snapshot
        s.isScanning = false
        s.scanStatusMessage = statusMessage
        s.scanProgress = nil
        s.liveDeltaCount = 0
        snapshot = s
        await YearScanRunner.persistPaused(
            environment: environment,
            scannedMessageCount: scannedMessageCount,
            statusMessage: statusMessage,
            resumeState: latestResumeState,
            configuration: configuration
        )
    }

    private func updateProgress(from state: YearScanResumeState) {
        var computedProgress: Double?
        switch state.phase {
        case .backfill:
            let totalMonths = max(state.totalMonths, 1)
            let totalSlices = max(totalMonths + 1, 1)
            let completedSlices = min(max(state.monthIndex, 0), totalMonths)
            computedProgress = Double(completedSlices) / Double(totalSlices)
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
            computedProgress = completedBase + (finalSliceWeight * scanCompletion)
        }

        if let computedProgress {
            let clamped = min(max(computedProgress, 0.0), 1.0)
            // Keep in-progress UI honest: only show 100% when run is actually complete.
            self.scanProgress = isScanning ? min(clamped, 0.99) : clamped
        }
    }

    private func shouldApplyIncomingResumeState(_ incoming: YearScanResumeState) -> Bool {
        Self.shouldApplyResumeState(current: latestResumeState, incoming: incoming)
    }

    static func shouldApplyResumeState(
        current: YearScanResumeState?,
        incoming: YearScanResumeState
    ) -> Bool {
        guard let current else { return true }

        // Never let older backfill updates overwrite active scanning state.
        if current.phase == .scanning, incoming.phase == .backfill {
            return false
        }

        if incoming.accountIndex < current.accountIndex {
            return false
        }

        if incoming.accountIndex == current.accountIndex {
            if incoming.phase == .backfill, current.phase == .backfill,
               incoming.monthIndex < current.monthIndex {
                return false
            }

            if incoming.phase == .scanning, current.phase == .scanning {
                let incomingPage = incoming.currentPage ?? 0
                let currentPage = current.currentPage ?? 0
                if incomingPage < currentPage {
                    return false
                }
                if incomingPage == currentPage, incoming.scannedMessageCount < current.scannedMessageCount {
                    return false
                }
            }
        }

        return true
    }
}
