import Foundation
import Combine

@MainActor
final class YearScanViewModel: ObservableObject {
    @Published private(set) var isLoading = false
    @Published private(set) var results: [YearScanItem] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var error: Error?
    @Published private(set) var scannedMessageCount: Int = 0
    @Published private(set) var statusMessage: String?
    @Published private(set) var isInProgress = false

    private(set) var coverageSummary = YearScanRunner.coverageSummary
    private var accountsById: [String: MailboxAccountRecord] = [:]
    private var scanTask: Task<Void, Never>?

    deinit {
        scanTask?.cancel()
    }

    func startScan(using environment: AppEnvironment) {
        guard scanTask == nil else { return }
        YearScanBackgroundManager.scheduleBackfill()
        scanTask = Task {
            await runScan(using: environment)
            scanTask = nil
        }
    }

    func restartScan(using environment: AppEnvironment) {
        scanTask?.cancel()
        scanTask = nil
        startScan(using: environment)
    }

    func loadCached(using environment: AppEnvironment) async {
        guard !isLoading else { return }
        if let snapshot = try? await environment.yearScanRepository.fetchLatest() {
            results = snapshot.items
            lastChecked = snapshot.lastChecked
            scannedMessageCount = snapshot.scannedMessageCount
            coverageSummary = snapshot.coverageSummary
            isInProgress = snapshot.isInProgress
            statusMessage = snapshot.statusMessage
        }
    }

    func runScan(using environment: AppEnvironment) async {
        isLoading = true
        error = nil
        scannedMessageCount = 0
        statusMessage = "Preparing scan..."
        isInProgress = true
        defer { isLoading = false }
        try? await environment.yearScanRepository.markInProgress(
            scannedMessageCount: scannedMessageCount,
            coverageSummary: coverageSummary,
            statusMessage: statusMessage
        )

        do {
            let accounts = try await environment.mailboxAccountRepository.fetchAll()
            accountsById = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })

            let runResult = try await YearScanRunner.run(environment: environment) { status in
                Task { @MainActor in
                    self.statusMessage = status
                    self.isInProgress = true
                    Task {
                        try? await environment.yearScanRepository.markInProgress(
                            scannedMessageCount: self.scannedMessageCount,
                            coverageSummary: self.coverageSummary,
                            statusMessage: status
                        )
                    }
                }
            }

            results = runResult.items
            scannedMessageCount = runResult.scannedMessageCount
            lastChecked = Date()
            statusMessage = nil
            isInProgress = false

            try await environment.yearScanRepository.saveRun(
                items: runResult.items,
                scannedMessageCount: runResult.scannedMessageCount,
                lastChecked: lastChecked,
                coverageSummary: coverageSummary
            )
        } catch {
            self.error = error
            results = []
            statusMessage = nil
            isInProgress = false
            Logger.info("YearScan: failed \(error)")
        }
    }

    func clearError() {
        error = nil
    }

    func dismiss(_ item: YearScanItem) {
        results.removeAll { $0.id == item.id }
    }

    func providerURL(for item: YearScanItem) -> URL? {
        let account = accountsById[item.mailboxAccountId]
        if account?.provider == .gmail {
            let target = item.threadId ?? item.providerMessageId
            return URL(string: "https://mail.google.com/mail/u/0/#inbox/\(target)")
        }
        return nil
    }
}
