import Foundation
import BackgroundTasks
import os

enum BackgroundSyncManager {
    static let taskIdentifier = "com.ondue.refresh"
    static let defaultEarliestInterval: TimeInterval = 60 * 60 * 6

    static func register(environmentProvider: @escaping () -> AppEnvironment) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask, environment: environmentProvider())
        }
    }

    static func schedule(earliestInterval: TimeInterval = defaultEarliestInterval) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: earliestInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NotificationCenter.default.post(
                name: .syncLog,
                object: "⚠️ Background sync schedule failed: \(error.localizedDescription)"
            )
        }
    }

    private static func handle(_ task: BGAppRefreshTask, environment: AppEnvironment) {
        scheduleIfEnabled(environment: environment)

        let work = Task {
            let restored = (try? await environment.gmailAuthService.restorePreviousSignIn()) ?? false
            guard restored else {
                task.setTaskCompleted(success: false)
                AppLog.debug("BackgroundSync.restoreFailed")
                return
            }

            let hydratedAccount: MailboxAccountRecord?
            if let email = environment.gmailAuthService.userEmail, !email.isEmpty {
                hydratedAccount = try? await environment.mailboxAccountRepository.getOrCreate(email: email, provider: .gmail)
            } else {
                hydratedAccount = try? await environment.mailboxAccountRepository.fetchFirst(provider: .gmail)
            }

            guard let account = hydratedAccount else {
                task.setTaskCompleted(success: false)
                AppLog.debug("BackgroundSync.noAccount")
                return
            }

            do {
                let report = try await environment.gmailSyncCoordinator.sync(
                    mailboxAccountId: account.id,
                    daysBack: environment.syncPolicyStore.defaultSyncRange.days,
                    forceFullSync: false
                )
                AppLog.info(
                    "BackgroundSync.complete",
                    fields: [
                        "mailboxAccountId": account.id,
                        "messageIDs": report.messageIDsCount,
                        "messagesSaved": report.messagesSavedCount,
                        "obligations": report.obligationsCount
                    ]
                )
                task.setTaskCompleted(success: true)
            } catch {
                AppLog.error(
                    "BackgroundSync.failed",
                    fields: ["error": error.localizedDescription]
                )
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            work.cancel()
        }
    }

    static func scheduleIfEnabled(environment: AppEnvironment) {
        guard environment.syncPolicyStore.backgroundSyncEnabled else { return }
        let interval = TimeInterval(environment.syncPolicyStore.backgroundIntervalHours * 60 * 60)
        schedule(earliestInterval: max(interval, 60 * 30))
    }

    static func cancelAllPendingTasks() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: YearScanBackgroundManager.taskIdentifier)
    }
}

enum AppLog {
    private static let subsystem = "com.ondue.app"
    private static let syncLogger = OSLog(subsystem: subsystem, category: "sync")

    static func info(_ message: String, fields: [String: CustomStringConvertible] = [:]) {
        log(.info, message, fields: fields)
    }

    static func debug(_ message: String, fields: [String: CustomStringConvertible] = [:]) {
        log(.debug, message, fields: fields)
    }

    static func error(_ message: String, fields: [String: CustomStringConvertible] = [:]) {
        log(.error, message, fields: fields)
    }

    private static func log(_ level: OSLogType, _ message: String, fields: [String: CustomStringConvertible]) {
        let payload = format(message: message, fields: fields)
        os_log("%{public}@", log: syncLogger, type: level, payload)
        print("🧾", payload)
        NotificationCenter.default.post(name: .syncLog, object: payload)
    }

    private static func format(message: String, fields: [String: CustomStringConvertible]) -> String {
        guard !fields.isEmpty else { return message }
        let sorted = fields.sorted { $0.key < $1.key }
        let suffix = sorted.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return "\(message) | \(suffix)"
    }
}

enum AppErrorClassifier {
    /// Cancellation and user-abort errors should not surface as user-facing failures.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == "Swift.CancellationError" {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return true
        }
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            return true
        }
        return false
    }

    static func shouldSuppressUserFacing(_ error: Error) -> Bool {
        isCancellation(error)
    }

    static func classLabel(for error: Error) -> String {
        if isCancellation(error) {
            return "cancelled"
        }

        if let authError = error as? GmailAuthError {
            switch authError {
            case .cancelled:
                return "cancelled"
            case .notSignedIn, .missingAccessToken:
                return "auth"
            case .signInFailed:
                return "auth_failed"
            }
        }

        if case GmailClientError.notAuthenticated = error {
            return "auth"
        }

        if case GmailClientError.apiError(let code, _) = error {
            if code == 401 || code == 403 { return "auth" }
            if code == 429 { return "quota" }
            return "api_\(code)"
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "network"
        }
        return "unknown"
    }
}

enum AppUserErrorMapper {
    static func message(for error: Error, fallback: String) -> String {
        if AppErrorClassifier.shouldSuppressUserFacing(error) {
            return fallback
        }

        if let authError = error as? GmailAuthError {
            switch authError {
            case .cancelled:
                return fallback
            case .notSignedIn:
                return "Not signed in to Google. Reconnect Gmail in Settings."
            case .missingAccessToken:
                return "Google access token missing. Reconnect Gmail in Settings."
            case .signInFailed(let underlying):
                return "Google sign-in failed: \(underlying.localizedDescription)"
            }
        }

        if case GmailClientError.notAuthenticated = error {
            return "Gmail authorization expired. Reconnect Gmail in Settings."
        }

        if case GmailClientError.apiError(let code, _) = error {
            if code == 401 || code == 403 {
                return "Gmail authorization expired. Reconnect Gmail in Settings."
            }
            if code == 429 {
                return "Gmail API limit reached. Please try again in a few minutes."
            }
        }

        return fallback
    }
}
