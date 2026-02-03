import Foundation
import Combine

extension Notification.Name {
    static let syncLog = Notification.Name("SyncLogNotification")
}

struct SyncLogEntry: Identifiable {
    let id = UUID().uuidString
    let timestamp: Date
    let message: String
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
    @Published private(set) var isResetting = false
    @Published private(set) var lastSyncReport: SyncReport?
    @Published private(set) var syncLogs: [SyncLogEntry] = []
    @Published var forceFullSync = false
    
    // MARK: - Private
    
    private var mailboxAccountId: String?
    private let lastConnectedAtKey = "gmail.lastConnectedAt"
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
            isSyncing = false
            statusMessage = "Error: \(error.localizedDescription)"
        }
    }
    
    func disconnect(using environment: AppEnvironment) {
        environment.gmailAuthService.signOut()
        isConnected = false
        userEmail = nil
        mailboxAccountId = nil
        statusMessage = nil
        lastSyncDate = nil
        lastSyncReport = nil
        UserDefaults.standard.removeObject(forKey: lastConnectedAtKey)
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
            statusMessage = "Reset failed: \(error.localizedDescription)"
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
        await backfillEmails(using: environment)
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
            statusMessage = "Sync failed: \(error.localizedDescription)"
        }
    }

    private func backfillEmails(using environment: AppEnvironment) async {
        guard let accountId = mailboxAccountId else { return }

        do {
            let endDate = Date()
            let startDate = Calendar.current.date(byAdding: .month, value: -12, to: endDate) ?? endDate
            statusMessage = "Backfilling last 12 months..."
            isBackfilling = true

            let report = try await environment.gmailSyncCoordinator.backfill(
                mailboxAccountId: accountId,
                startDate: startDate,
                endDate: endDate,
                daysBackForExtraction: 365
            )
            lastSyncReport = report
            AppLog.info(
                "BackfillUI.complete",
                fields: [
                    "messageIDs": report.messageIDsCount,
                    "messagesSaved": report.messagesSavedCount,
                    "obligations": report.obligationsCount
                ]
            )

            lastSyncDate = Date()
            isBackfilling = false
            statusMessage = "Backfill complete: searched \(report.messageIDsCount), saved \(report.messagesSavedCount), obligations \(report.obligationsCount)"

        } catch {
            isBackfilling = false
            statusMessage = "Backfill failed: \(error.localizedDescription)"
        }
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
