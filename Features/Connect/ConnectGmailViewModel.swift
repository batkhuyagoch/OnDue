import Foundation
import Combine
import BackgroundTasks

extension Notification.Name {
    static let syncLog = Notification.Name("SyncLogNotification")
}

struct SyncLogEntry: Identifiable {
    let id = UUID().uuidString
    let timestamp: Date
    let message: String
}

/// Lightweight resumable state when backfill stops (user stop or quota error)
struct BackfillResumableState {
    let lastCompletedMonth: Int
    let totalMonths: Int
    let accountId: String
    let isQuotaError: Bool
}

@MainActor
final class ConnectGmailViewModel: ObservableObject {
    
    // MARK: - Published State
    
    @Published private(set) var isConnected = false
    @Published private(set) var userEmail: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isSyncing = false
    @Published private(set) var lastSyncDate: Date?
    @Published private(set) var isBackfilling = false
    @Published private(set) var backfillProgressMonth: Int?
    @Published private(set) var backfillTotalMonths: Int = 12
    @Published private(set) var backfillResumableState: BackfillResumableState?
    @Published private(set) var isResetting = false
    @Published private(set) var lastSyncReport: SyncReport?
    @Published private(set) var syncLogs: [SyncLogEntry] = []
    @Published var forceFullSync = false
    
    // MARK: - Private
    
    private var mailboxAccountId: String?
    private var requestBackfillStop = false
    private let lastConnectedAtKey = "gmail.lastConnectedAt"
    private let backfillResumableKey = "gmail.backfill.resumable"
    private let lastConnectedTTL: TimeInterval = 7 * 24 * 60 * 60
    private var syncLogObserver: NSObjectProtocol?

    init() {
        syncLogObserver = NotificationCenter.default.addObserver(
            forName: .syncLog,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let message = notification.object as? String else { return }
            DispatchQueue.main.async { [weak self] in
                self?.appendLog(message)
            }
        }
    }

    deinit {
        if let observer = syncLogObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    // MARK: - Actions

    func checkConnection(using environment: AppEnvironment) async {
        if environment.gmailAuthService.isSignedIn {
            isConnected = true
            userEmail = environment.gmailAuthService.userEmail
            if let email = userEmail {
                let account = try? await environment.mailboxAccountRepository.getOrCreate(
                    email: email,
                    provider: .gmail
                )
                mailboxAccountId = account?.id
            }
            if let persisted = loadPersistedBackfillResumable(),
               persisted.accountId == mailboxAccountId {
                backfillResumableState = persisted
            }
            return
        }
        
        guard let lastConnectedAt = UserDefaults.standard.object(forKey: lastConnectedAtKey) as? Date else {
            isConnected = false
            userEmail = nil
            return
        }
        
        let age = Date().timeIntervalSince(lastConnectedAt)
        guard age <= lastConnectedTTL else {
            isConnected = false
            userEmail = nil
            return
        }
        
        do {
            let restored = try await environment.gmailAuthService.restorePreviousSignIn()
            if restored {
                isConnected = true
                userEmail = environment.gmailAuthService.userEmail
                if let email = userEmail {
                    let account = try await environment.mailboxAccountRepository.getOrCreate(
                        email: email,
                        provider: .gmail
                    )
                    mailboxAccountId = account.id
                }
            } else {
                isConnected = false
                userEmail = nil
            }
        } catch {
            isConnected = false
            userEmail = nil
        }
    }
    
    func connect(using environment: AppEnvironment) async {
        do {
            statusMessage = "Connecting..."
            try await environment.gmailAuthService.authorize()
            
            guard let email = environment.gmailAuthService.userEmail else {
                statusMessage = "Failed to get user info"
                return
            }
            
            isConnected = true
            userEmail = email
            
            // Create or get mailbox account via repository
            let account = try await environment.mailboxAccountRepository.getOrCreate(
                email: email,
                provider: .gmail
            )
            mailboxAccountId = account.id
            UserDefaults.standard.set(Date(), forKey: lastConnectedAtKey)
            
            await syncEmails(using: environment)
            
        } catch GmailAuthError.cancelled {
            statusMessage = nil
        } catch {
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                AppLog.debug(
                    "Connect.connect.suppressed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                statusMessage = nil
                return
            }
            isSyncing = false
            AppLog.error(
                "Connect.connect.failed",
                fields: [
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            statusMessage = AppUserErrorMapper.message(for: error, fallback: "Unable to connect Gmail. Please try again.")
        }
    }
    
    func disconnect(using environment: AppEnvironment) {
        BackgroundSyncManager.cancelAllPendingTasks()
        environment.gmailAuthService.signOut()
        isConnected = false
        userEmail = nil
        mailboxAccountId = nil
        statusMessage = nil
        lastSyncDate = nil
        lastSyncReport = nil
        backfillResumableState = nil
        UserDefaults.standard.removeObject(forKey: lastConnectedAtKey)
        clearPersistedBackfillResumable()
    }

    func resetLocalData(using environment: AppEnvironment) async {
        guard let accountId = mailboxAccountId else {
            statusMessage = "Connect first to reset local data"
            return
        }

        isResetting = true
        statusMessage = "Clearing local cache..."
        do {
            let deleted = try await environment.gmailSyncCoordinator.resetLocalCache(
                mailboxAccountId: accountId
            )
            AppLog.info(
                "SyncUI.resetLocalCache",
                fields: ["deleted": deleted]
            )
            statusMessage = "Local cache cleared (\(deleted) messages)"
            lastSyncReport = nil
        } catch {
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                AppLog.debug(
                    "Connect.resetLocalData.suppressed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                statusMessage = nil
                isResetting = false
                return
            }
            AppLog.error(
                "Connect.resetLocalData.failed",
                fields: [
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            statusMessage = AppUserErrorMapper.message(for: error, fallback: "Unable to clear local cache. Please try again.")
        }
        isResetting = false
    }

    func deleteAllAccountData(using environment: AppEnvironment) async {
        guard let accountId = mailboxAccountId else {
            statusMessage = "Connect first to remove account data"
            return
        }

        isResetting = true
        statusMessage = "Removing all account data..."
        do {
            try await environment.gmailSyncCoordinator.deleteAllAccountData(
                mailboxAccountId: accountId
            )
            AppLog.info("SyncUI.deleteAllAccountData", fields: ["mailboxAccountId": accountId])
            environment.gmailAuthService.signOut()
            BackgroundSyncManager.cancelAllPendingTasks()
            isConnected = false
            userEmail = nil
            mailboxAccountId = nil
            statusMessage = "All account data removed"
            lastSyncDate = nil
            lastSyncReport = nil
            backfillResumableState = nil
            UserDefaults.standard.removeObject(forKey: lastConnectedAtKey)
            clearPersistedBackfillResumable()
        } catch {
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                AppLog.debug(
                    "Connect.deleteAllData.suppressed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                statusMessage = nil
                isResetting = false
                return
            }
            AppLog.error(
                "Connect.deleteAllData.failed",
                fields: [
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            statusMessage = AppUserErrorMapper.message(for: error, fallback: "Unable to remove account data. Please try again.")
        }
        isResetting = false
    }

    func addTestLog() {
        let message = "TestLog | time=\(Date())"
        appendLog(message)
        print("🧾", message)
    }

    func resync(using environment: AppEnvironment) async {
        guard mailboxAccountId != nil else {
            statusMessage = "Not connected"
            return
        }
        await syncEmails(using: environment)
    }

    func backfillLast12Months(using environment: AppEnvironment) async {
        guard mailboxAccountId != nil else {
            statusMessage = "Not connected"
            return
        }
        backfillResumableState = nil
        clearPersistedBackfillResumable()
        await backfillEmails(using: environment, resumeFromMonth: nil)
    }

    func stopBackfill() {
        requestBackfillStop = true
    }

    func resumeBackfill(using environment: AppEnvironment) async {
        guard let accountId = mailboxAccountId else {
            statusMessage = "Not connected"
            return
        }
        guard let resumable = backfillResumableState ?? loadPersistedBackfillResumable(),
              resumable.accountId == accountId else {
            statusMessage = "Nothing to resume"
            return
        }
        let startFrom = resumable.lastCompletedMonth + 1
        backfillResumableState = nil
        clearPersistedBackfillResumable()
        await backfillEmails(using: environment, resumeFromMonth: startFrom)
    }
    
    // MARK: - Private Helpers
    
    private func syncEmails(using environment: AppEnvironment) async {
        guard let accountId = mailboxAccountId else { return }
        
        do {
            let daysBack = environment.syncPolicyStore.defaultSyncRange.days
            statusMessage = "Syncing emails..."
            isSyncing = true

            let report = try await environment.gmailSyncCoordinator.sync(
                mailboxAccountId: accountId,
                daysBack: daysBack,
                forceFullSync: forceFullSync
            )
            lastSyncReport = report
            AppLog.info(
                "SyncUI.complete",
                fields: [
                    "messageIDs": report.messageIDsCount,
                    "messagesSaved": report.messagesSavedCount,
                    "obligations": report.obligationsCount,
                    "softDeleted": report.deletedOldMessagesCount
                ]
            )
            
            lastSyncDate = Date()
            isSyncing = false
            statusMessage = "Sync complete: searched \(report.messageIDsCount), saved \(report.messagesSavedCount), obligations \(report.obligationsCount)"
            if report.deletedOldMessagesCount > 0 {
                statusMessage = "Sync complete: searched \(report.messageIDsCount), saved \(report.messagesSavedCount), obligations \(report.obligationsCount) (deleted \(report.deletedOldMessagesCount))"
            }
            forceFullSync = false
            
        } catch {
            isSyncing = false
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                AppLog.debug(
                    "Connect.sync.suppressed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                statusMessage = nil
                return
            }
            AppLog.error(
                "Connect.sync.failed",
                fields: [
                    "errorClass": AppErrorClassifier.classLabel(for: error),
                    "error": error.localizedDescription
                ]
            )
            statusMessage = AppUserErrorMapper.message(for: error, fallback: "Sync failed. Please try again.")
        }
    }

    private func backfillEmails(using environment: AppEnvironment, resumeFromMonth: Int?) async {
        guard let accountId = mailboxAccountId else { return }

        let endDate = Date()
        let startDate = Calendar.current.date(byAdding: .month, value: -12, to: endDate) ?? endDate
        let monthRanges = buildMonthRanges(startDate: startDate, endDate: endDate)
        let totalMonths = monthRanges.count
        let startIndex = resumeFromMonth ?? 0

        requestBackfillStop = false
        isBackfilling = true
        backfillTotalMonths = totalMonths

        var aggMessageIDs = 0
        var aggSaved = 0
        var aggObligations = 0
        var lastCompletedMonth = startIndex - 1

        defer {
            isBackfilling = false
            backfillProgressMonth = nil
        }

        do {
            for (index, range) in monthRanges.enumerated() where index >= startIndex {
                if requestBackfillStop {
                    lastCompletedMonth = index - 1
                    let state = BackfillResumableState(
                        lastCompletedMonth: lastCompletedMonth,
                        totalMonths: totalMonths,
                        accountId: accountId,
                        isQuotaError: false
                    )
                    backfillResumableState = state
                    persistBackfillResumable(state)
                    if lastCompletedMonth < 0 {
                        statusMessage = "Stopped before completing month 1. Tap Resume to continue."
                    } else {
                        statusMessage = "Stopped at month \(lastCompletedMonth + 1) of \(totalMonths). Tap Resume to continue."
                    }
                    lastSyncReport = SyncReport(
                        messageIDsCount: aggMessageIDs,
                        messagesSavedCount: aggSaved,
                        obligationsCount: aggObligations,
                        deletedOldMessagesCount: 0
                    )
                    return
                }

                backfillProgressMonth = index + 1
                statusMessage = "Backfilling month \(index + 1) of \(totalMonths)..."

                let report = try await environment.gmailSyncCoordinator.backfill(
                    mailboxAccountId: accountId,
                    startDate: range.start,
                    endDate: range.end,
                    daysBackForExtraction: 0
                )
                aggMessageIDs += report.messageIDsCount
                aggSaved += report.messagesSavedCount
                lastCompletedMonth = index
            }

            if totalMonths > 0 {
                let recentMessages = try await environment.messageRepository.fetchRecent(
                    mailboxAccountId: accountId,
                    daysBack: 365
                )
                let obligations = try await environment.obligationExtractor.extract(
                    from: recentMessages,
                    mailboxAccountId: accountId
                )
                try await environment.obligationRepository.save(obligations)
                aggObligations = obligations.count
            }

            lastSyncReport = SyncReport(
                messageIDsCount: aggMessageIDs,
                messagesSavedCount: aggSaved,
                obligationsCount: aggObligations,
                deletedOldMessagesCount: 0
            )
            lastSyncDate = Date()
            backfillResumableState = nil
            clearPersistedBackfillResumable()
            statusMessage = "Backfill complete: searched \(aggMessageIDs), saved \(aggSaved), obligations \(aggObligations)"

            AppLog.info(
                "BackfillUI.complete",
                fields: [
                    "messageIDs": aggMessageIDs,
                    "messagesSaved": aggSaved,
                    "obligations": aggObligations
                ]
            )

        } catch {
            if AppErrorClassifier.shouldSuppressUserFacing(error) {
                AppLog.debug(
                    "Connect.backfill.suppressed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                statusMessage = nil
                return
            }
            let isQuota = Self.isQuotaRelatedError(error)
            let state = BackfillResumableState(
                lastCompletedMonth: lastCompletedMonth,
                totalMonths: totalMonths,
                accountId: accountId,
                isQuotaError: isQuota
            )
            backfillResumableState = state
            persistBackfillResumable(state)
            if isQuota {
                if lastCompletedMonth < 0 {
                    statusMessage = "API limit reached before completing month 1. Tap Resume later to continue."
                } else {
                    statusMessage = "API limit reached at month \(lastCompletedMonth + 1) of \(totalMonths). Tap Resume later to continue."
                }
            } else {
                AppLog.error(
                    "Connect.backfill.failed",
                    fields: [
                        "errorClass": AppErrorClassifier.classLabel(for: error),
                        "error": error.localizedDescription
                    ]
                )
                statusMessage = AppUserErrorMapper.message(for: error, fallback: "Backfill failed. Please try again.")
            }
        }
    }

    private static func isQuotaRelatedError(_ error: Error) -> Bool {
        if case GmailClientError.apiError(let code, _) = error {
            return code == 429 || code == 403
        }
        return false
    }

    private func buildMonthRanges(startDate: Date, endDate: Date) -> [(start: Date, end: Date)] {
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

    private func persistBackfillResumable(_ state: BackfillResumableState) {
        let dict: [String: Any] = [
            "lastCompletedMonth": state.lastCompletedMonth,
            "totalMonths": state.totalMonths,
            "accountId": state.accountId,
            "isQuotaError": state.isQuotaError
        ]
        UserDefaults.standard.set(dict, forKey: backfillResumableKey)
    }

    private func loadPersistedBackfillResumable() -> BackfillResumableState? {
        guard let dict = UserDefaults.standard.dictionary(forKey: backfillResumableKey),
              let lastCompletedMonth = dict["lastCompletedMonth"] as? Int,
              let totalMonths = dict["totalMonths"] as? Int,
              let accountId = dict["accountId"] as? String,
              let isQuotaError = dict["isQuotaError"] as? Bool else {
            return nil
        }
        return BackfillResumableState(
            lastCompletedMonth: lastCompletedMonth,
            totalMonths: totalMonths,
            accountId: accountId,
            isQuotaError: isQuotaError
        )
    }

    private func clearPersistedBackfillResumable() {
        UserDefaults.standard.removeObject(forKey: backfillResumableKey)
    }

    private func appendLog(_ message: String) {
        syncLogs.append(SyncLogEntry(timestamp: Date(), message: message))
        if syncLogs.count > 200 {
            syncLogs.removeFirst(syncLogs.count - 200)
        }
    }
}

enum SyncRange: String, CaseIterable, Identifiable {
    case sevenDays
    case threeWeeks

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sevenDays: "Last 7 Days"
        case .threeWeeks: "Last 3 Weeks"
        }
    }

    var days: Int {
        switch self {
        case .sevenDays: 7
        case .threeWeeks: 21
        }
    }
}
