import SwiftUI
import Combine

struct YearScanBanner: View {
    @ObservedObject var state: YearScanState
    @EnvironmentObject private var environmentStore: AppEnvironmentStore
    @State private var isDismissed = false

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
        }
    }
}

@MainActor
class YearScanState: ObservableObject {
    @Published var lastScanDate: Date?
    @Published var isScanning = false
    @Published var scanProgress: Double?
    @Published var foundItemsCount = 0
    @Published var unseenItemsCount = 0
    @Published var scannedMessageCount = 0
    @Published var scanStatusMessage: String?
    @Published var livePromotedPreview: [YearScanItem] = []
    @Published var liveDeltaCount: Int = 0
    @Published var currentPhase: YearScanPhase?
    @Published var currentMonthIndex: Int?
    @Published var totalMonths: Int?
    @Published var monthSummaries: [YearScanMonthSummary] = []
    private var estimatedScanMessages: Int?

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
            return "Scanning your inbox..."
        } else if lastScanDate == nil {
            return "Scan your past year"
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
            return scannedMessageCount > 0 ? "Analyzed \(scannedMessageCount) messages" : "Starting scan..."
        } else if lastScanDate == nil {
            return "Find obligations you might have missed"
        } else if unseenItemsCount > 0 {
            return "Tap to review what we found"
        } else {
            return "Scan again to find new obligations"
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
            if let snapshot = try await environment.yearScanRepository.fetchLatest() {
                lastScanDate = snapshot.lastChecked
                foundItemsCount = snapshot.items.count
                scannedMessageCount = snapshot.scannedMessageCount
                scanStatusMessage = snapshot.statusMessage
                livePromotedPreview = Array(snapshot.items.prefix(5))
                liveDeltaCount = 0
                if let resume = snapshot.resumeState {
                    currentPhase = resume.phase
                    currentMonthIndex = resume.monthIndex
                    totalMonths = resume.totalMonths
                    monthSummaries = resume.monthSummaries ?? []
                } else {
                    currentPhase = nil
                    currentMonthIndex = nil
                    totalMonths = nil
                    monthSummaries = []
                }

                if snapshot.isInProgress {
                    if let updatedAt = snapshot.updatedAt {
                        let timeSinceUpdate = Date().timeIntervalSince(updatedAt)
                        isScanning = timeSinceUpdate < 300
                        if isScanning, let resumeState = snapshot.resumeState {
                            updateProgress(from: resumeState)
                        }

                        if !isScanning {
                            try? await environment.yearScanRepository.clearResumeState()
                        }
                    } else {
                        isScanning = false
                        try? await environment.yearScanRepository.clearResumeState()
                    }
                } else {
                    isScanning = false
                }
            }
        } catch {
            lastScanDate = nil
            isScanning = false
        }
    }

    func startScan(using environment: AppEnvironment) async {
        isScanning = true
        scanProgress = 0
        scanStatusMessage = "Preparing scan..."
        livePromotedPreview = []
        liveDeltaCount = 0
        currentPhase = nil
        currentMonthIndex = nil
        totalMonths = nil
        monthSummaries = []
        let runConfiguration = YearScanRunner.RunConfiguration.from(policy: environment.syncPolicyStore)
        let restoredSession = (try? await environment.gmailAuthService.restorePreviousSignIn()) ?? false
        guard restoredSession else {
            isScanning = false
            scanProgress = nil
            scanStatusMessage = "Gmail session expired. Reconnect Gmail in Settings to run scan."
            return
        }

        do {
            let runToken = UUID().uuidString
            var partialSequence = 0
            await YearScanCoordinator.persistInProgress(
                environment: environment,
                scannedMessageCount: scannedMessageCount,
                statusMessage: scanStatusMessage,
                resumeState: nil,
                configuration: runConfiguration
            )
            let result = try await YearScanCoordinator.run(
                environment: environment,
                resumeState: nil,
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
                        self.scannedMessageCount = checkpoint.scannedMessageCount
                        self.updateProgress(from: checkpoint)
                        self.currentPhase = checkpoint.phase
                        self.currentMonthIndex = checkpoint.monthIndex
                        self.totalMonths = checkpoint.totalMonths
                        self.monthSummaries = checkpoint.monthSummaries ?? []
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
                },
                partialUpdate: { [weak self] update in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let previousCount = self.foundItemsCount
                        self.scannedMessageCount = update.scannedMessageCount
                        self.scanStatusMessage = CoverageStatusPresenter.progressMessage(from: update.statusMessage)
                        self.updateProgress(from: update.resumeState)
                        self.currentPhase = update.resumeState.phase
                        self.currentMonthIndex = update.resumeState.monthIndex
                        self.totalMonths = update.resumeState.totalMonths
                        self.monthSummaries = update.resumeState.monthSummaries ?? []
                        let promotedCount = update.items.filter { $0.promotionDecision == .promoted }.count
                        self.foundItemsCount = promotedCount
                        self.unseenItemsCount = promotedCount
                        self.liveDeltaCount = max(0, promotedCount - previousCount)
                        self.livePromotedPreview = Array(
                            update.items
                                .filter { $0.promotionDecision == .promoted }
                                .sorted { $0.detectedAt > $1.detectedAt }
                                .prefix(5)
                        )
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

            foundItemsCount = result.items.count
            unseenItemsCount = result.items.count
            livePromotedPreview = Array(
                result.items
                    .filter { $0.promotionDecision == .promoted }
                    .sorted { $0.detectedAt > $1.detectedAt }
                    .prefix(5)
            )
            liveDeltaCount = 0
            lastScanDate = Date()
            isScanning = false
            scanProgress = nil
            scanStatusMessage = nil
            currentPhase = nil
            currentMonthIndex = nil
            totalMonths = nil
            monthSummaries = []
            let excluded = (try? await environment.messageStateManager.getExcludedMessageIDsCached(maxAge: 0)) ?? []
            try? await environment.yearScanRepository.saveRun(
                items: result.items,
                scannedMessageCount: result.scannedMessageCount,
                lastChecked: lastScanDate,
                coverageSummary: YearScanRunner.coverageSummary,
                scanRangeMonths: runConfiguration.rangeMonths,
                scanIntensity: runConfiguration.intensity.rawValue,
                excludedProviderMessageIds: excluded
            )
            await YearScanCoordinator.bridgePromotedFindingsToObligations(
                environment: environment,
                items: result.items
            )
        } catch {
            isScanning = false
            scanProgress = nil
            liveDeltaCount = 0
            if Self.isAuthenticationError(error) {
                scanStatusMessage = "Gmail authorization expired. Reconnect Gmail in Settings."
            } else {
                scanStatusMessage = "Scan failed. Try again."
            }
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
}
